# Phân tích: Karpenter giữ 4 Spot node khi hệ thống ít traffic

## Tóm tắt

Ngày 2026-07-16, cluster `techx-tf2-prod` đang có tổng cộng 6 node đang hoạt động:

| Nhóm node | Số lượng | Vai trò |
|---|---:|---|
| Managed node group On-Demand | 2 | Nền tảng/critical workload |
| Karpenter `stateless-spot` | 4 | Workload stateless có toleration spot |

Kết luận chính: số lượng 6 node hiện tại không đến từ traffic hoặc load-generator đang chạy mạnh. HPA của các service chính đang ở mức tối thiểu, không có pod Pending, CPU thực tế trên các Spot node rất thấp. Nguyên nhân giữ lại 4 Spot node là Karpenter đã thấy các node có thể consolidate, nhưng hành động tối ưu tiếp theo cần thay Spot node bằng Spot node khác; cluster hiện đang tắt feature gate `SpotToSpotConsolidation`, nên Karpenter không được phép thực hiện bước replace/repack đó.

## Bằng chứng đã kiểm tra

### 1. Trạng thái node hiện tại

Lệnh kiểm tra:

```bash
kubectl get nodes -o wide --show-labels
kubectl get nodeclaims,nodepools -A -o wide
```

Kết quả chính:

| Node | Loại | NodePool / NodeGroup | Ghi chú |
|---|---|---|---|
| `ip-10-0-28-93` | `t4g.large` On-Demand | `techx-tf2-prod-system-1a` | Managed node group critical |
| `ip-10-0-42-74` | `t4g.large` On-Demand | `techx-tf2-prod-system-1b` | Managed node group critical |
| `ip-10-0-18-140` | `c6g.large` Spot | `stateless-spot` | Karpenter |
| `ip-10-0-29-114` | `c9g.large` Spot | `stateless-spot` | Karpenter |
| `ip-10-0-34-40` | `c9g.large` Spot | `stateless-spot` | Karpenter |
| `ip-10-0-46-8` | `c9g.large` Spot | `stateless-spot` | Karpenter |

`stateless-on-demand` hiện có 0 node, còn `stateless-spot` có 4 node.

### 2. Không có dấu hiệu scale vì traffic hiện tại

Lệnh kiểm tra:

```bash
kubectl -n techx-corp-prod get hpa,deploy,pods -o wide
kubectl get pods -A --field-selector=status.phase=Pending -o wide
```

Kết quả chính:

| Workload | HPA hiện tại |
|---|---|
| `cart` | `2/12` |
| `checkout` | `2/16` |
| `currency` | `2/72` |
| `frontend` | `3/20` |
| `frontend-proxy` | `2/10` |
| `load-generator-worker` | `1/8` |
| `product-catalog` | `2/12` |
| `product-reviews` | `2/6` |
| `quote` | `2/4` |
| `shipping` | `2/4` |

Không có pod ở trạng thái `Pending`. Điều này loại trừ khả năng Karpenter đang giữ 4 Spot node vì workload mới không schedule được.

### 3. CPU thực tế thấp, nhưng requests vẫn chiếm chỗ

Lệnh kiểm tra:

```bash
kubectl top nodes
kubectl get nodes -l karpenter.sh/nodepool=stateless-spot -o name | xargs -I{} sh -c 'echo ==== {}; kubectl describe {} | sed -n "/Allocated resources:/,/Events:/p"'
```

CPU thực tế trên Spot node thấp:

| Node Spot | CPU thực tế | Memory thực tế |
|---|---:|---:|
| `ip-10-0-18-140` | `40m`, khoảng 2% | 41% |
| `ip-10-0-29-114` | `24m`, khoảng 1% | 56% |
| `ip-10-0-34-40` | `31m`, khoảng 1% | 55% |
| `ip-10-0-46-8` | `13m`, khoảng 0% | 33% |

Tuy nhiên Karpenter không dựa vào CPU thực tế để bin-pack, mà dựa vào resource requests, PDB, topology và scheduling constraints. Requests trên các Spot node:

| Node Spot | CPU requests | Memory requests |
|---|---:|---:|
| `ip-10-0-18-140` | `820m`, 42% | `2102Mi`, 67% |
| `ip-10-0-29-114` | `615m`, 31% | `1534Mi`, 55% |
| `ip-10-0-34-40` | `1025m`, 53% | `2574Mi`, 92% |
| `ip-10-0-46-8` | `365m`, 18% | `446Mi`, 16% |

Vì một số node không rỗng và có requests tương đối cao, Karpenter không thể chỉ xóa thẳng node một cách an toàn. Nó cần tạo hoặc chọn bố cục Spot node thay thế để repack pod.

### 4. Karpenter muốn consolidate nhưng bị chặn

Lệnh kiểm tra:

```bash
kubectl get events -A --field-selector reason=Unconsolidatable --sort-by=.lastTimestamp
kubectl get nodeclaims -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.creationTimestamp}{"\t"}{.status.nodeName}{"\t"}{.status.conditions[?(@.type=="Consolidatable")].status}{"\t"}{.status.conditions[?(@.type=="Consolidatable")].reason}{"\n"}{end}'
```

Kết quả chính:

```text
SpotToSpotConsolidation is disabled, can't replace a spot node with a spot node
```

Các NodeClaim còn lại đều có trạng thái:

```text
Consolidatable=True
Reason=Consolidatable
```

Diễn giải: Karpenter đã nhận ra có cơ hội consolidation, nhưng hành động cần thiết là thay Spot node hiện tại bằng Spot node khác. Feature này đang bị tắt, nên Karpenter chỉ ghi event `Unconsolidatable` và giữ nguyên node.

### 5. Feature gate đang tắt trên Karpenter controller

Lệnh kiểm tra:

```bash
kubectl -n kube-system get deploy karpenter -o yaml
```

Giá trị live:

```text
FEATURE_GATES=ReservedCapacity=true,SpotToSpotConsolidation=false,NodeRepair=false,NodeOverlay=false,StaticCapacity=false
```

Đây là nguyên nhân trực tiếp khiến Karpenter không scale Spot node xuống thêm trong trường hợp cần replace Spot bằng Spot.

### 6. NodePool đang cho phép consolidation

Lệnh kiểm tra:

```bash
kubectl describe nodepool stateless-spot
```

Cấu hình live:

```yaml
disruption:
  budgets:
    nodes: "1"
  consolidateAfter: 0s
  consolidationPolicy: WhenEmptyOrUnderutilized
```

Điều này cho thấy NodePool không bị freeze. Budget `nodes: 1` cho phép voluntary disruption từng node một. `consolidateAfter: 0s` còn làm Karpenter cố reclaim rất nhanh. Vấn đề không nằm ở NodePool budget.

### 7. Live config đang lệch với repo

Lệnh kiểm tra:

```bash
helm -n kube-system history karpenter-node-resources
helm -n kube-system get values karpenter-node-resources
rg -n "karpenter_consolidate_after|consolidateAfter" -S techx-corp-infra
```

Live Helm values:

```yaml
consolidateAfter: 0s
```

Repo production sau khi cập nhật `origin/main` hiện tại:

```hcl
karpenter_consolidate_after = "0s"
```

Trước khi cập nhật `origin/main`, local repo cũ còn hiển thị `1m`; remote mới đã đưa `0s` vào source-of-truth với mục tiêu reclaim ngay khi node empty/underutilized.

Lưu ý: `consolidateAfter: 0s` không phải nguyên nhân làm node bị giữ lại. Nó chỉ làm consolidation aggressive hơn. Nguyên nhân giữ node là `SpotToSpotConsolidation=false`.

### 8. Karpenter đã từng scale down được, nhưng dừng ở 4 Spot node

Log Karpenter cho thấy controller đã xóa nhiều node empty/underutilized trong khoảng `2026-07-15T16:54Z` đến `2026-07-15T17:02Z`, ví dụ:

```text
command="Empty/... delete ..."
command="Underutilized/... delete ..."
message="deleted node"
message="deleted nodeclaim"
```

Điều này xác nhận Karpenter vẫn hoạt động. Nó không bị hỏng controller, không bị thiếu quyền cơ bản, và không bị budget chặn hoàn toàn. Nó chỉ bị chặn ở bước tối ưu sâu hơn do Spot-to-Spot consolidation đang tắt.

## Nguyên nhân tổng hợp

### Nguyên nhân trực tiếp

`SpotToSpotConsolidation=false` trên Karpenter controller làm Karpenter không được phép thay Spot node hiện tại bằng Spot node khác để gom pod và giảm số node.

### Nguyên nhân góp phần

1. Các service stateless có baseline replica khá cao dù traffic thấp, nhiều workload đang `minReplicas=2`.
2. Pod được trải đều trên nhiều node theo scheduler/topology/PDB, làm node không rỗng hoàn toàn.
3. Karpenter bin-pack theo resource requests, không theo CPU live. Vì vậy CPU thấp không đồng nghĩa node có thể xóa ngay.
4. `consolidateAfter=0s` làm reclaim rất nhanh; cấu hình này phù hợp mục tiêu giảm node nhanh nhưng cần đi cùng disruption budget để tránh churn quá mạnh.
5. NodePool Spot đang có weight `100`, On-Demand `10`, nên workload stateless ưu tiên chạy trên Spot. Đây là đúng với mục tiêu tiết kiệm chi phí, nhưng nếu tắt Spot-to-Spot consolidation thì việc tối ưu lại bố cục Spot bị giới hạn.

## Những khả năng đã loại trừ

| Giả thuyết | Kết luận | Lý do |
|---|---|---|
| Traffic hiện tại cao | Loại trừ | HPA ở gần min replicas, CPU thấp |
| Load-generator đang scale mạnh | Loại trừ | `load-generator-worker` chỉ `1/8` |
| Pod Pending buộc Karpenter giữ node | Loại trừ | Không có pod Pending |
| NodePool bị freeze disruption budget | Loại trừ | Budget Spot là `nodes: 1` |
| Karpenter controller không hoạt động | Loại trừ | Log cho thấy đã delete nhiều empty/underutilized node |
| `consolidateAfter=0s` làm giữ node | Loại trừ | `0s` làm reclaim nhanh hơn, không làm chậm scale-down |

## Phương án scale node xuống tối ưu

### Mục tiêu

Scale số Karpenter Spot node xuống khi traffic thấp, nhưng hạn chế ảnh hưởng khách hàng:

1. Không tắt toàn bộ cơ chế autoscaling.
2. Không xóa node hàng loạt.
3. Không làm gián đoạn các service đang có replica tối thiểu.
4. Giữ khả năng tự phục hồi khi traffic tăng lại.
5. Đưa cấu hình live quay về quản lý bằng IaC để tránh drift.

### Phương án đề xuất

Phương án tối ưu là xử lý theo 3 bước, từ ít rủi ro tới bền vững. Phần IaC đã được chuẩn bị để thực hiện bước 1 và bước 2 trong cùng một lần apply.

#### Bước 1: Giữ production `consolidateAfter=0s` theo latest main

Giữ production NodePool ở giá trị source-of-truth mới:

```hcl
karpenter_consolidate_after = "0s"
```

Lý do:

* `0s` không phải nguyên nhân giữ node; nó giúp Karpenter reclaim ngay khi node empty/underutilized.
* Production latest main đã chọn `0s`, nên không đổi ngược về `1m`.
* Disruption budget `nodes: 1` vẫn giới hạn voluntary disruption, giảm rủi ro churn hàng loạt.

Kỳ vọng sau bước này: node count có thể không giảm ngay, vì blocker chính vẫn là Spot-to-Spot consolidation.

#### Bước 2: Bật Spot-to-Spot consolidation bằng IaC

Expose feature gate cho Helm release `karpenter` trong module, rồi bật trong production:

```yaml
settings:
  featureGates:
    spotToSpotConsolidation: true
```

Karpenter chart `1.13.1` dùng key `spotToSpotConsolidation`. Sau khi Helm render, deployment sẽ có:

```text
FEATURE_GATES=...,SpotToSpotConsolidation=true,...
```

Lý do đây là phương án tối ưu:

* Đúng trực tiếp vào blocker đã được Karpenter event xác nhận.
* Không cần tắt HPA, không cần tắt Karpenter, không cần giảm replica thủ công khi chưa có phân tích SLO.
* Karpenter sẽ tự tính toán replace/repack dựa trên requests, PDB và scheduling constraints.
* Disruption budget `nodes: 1` vẫn giới hạn mỗi lần chỉ một node/pool bị voluntary disruption, giảm rủi ro gián đoạn.

Kỳ vọng sau bước này:

* Karpenter có thể thay các Spot node hiện tại bằng bố cục ít node hơn hoặc instance type phù hợp hơn.
* Số Spot node có khả năng giảm từ 4 xuống thấp hơn nếu pod requests/PDB/topology cho phép.

Các file IaC liên quan:

| File | Thay đổi |
|---|---|
| `modules/karpenter/variables.tf` | Thêm biến `feature_gates` cho controller Helm chart |
| `modules/karpenter/main.tf` | Truyền `settings.featureGates` vào Helm release `karpenter` |
| `environments/production/variables.tf` | Thêm biến `karpenter_feature_gates` |
| `environments/production/main.tf` | Truyền `karpenter_feature_gates` vào module |
| `environments/production/terraform.tfvars` | Bật `spotToSpotConsolidation = true`, giữ `karpenter_consolidate_after = "0s"` |

#### Bước 3: Tối ưu baseline workload nếu vẫn còn nhiều node

Nếu sau khi bật Spot-to-Spot consolidation mà node vẫn không giảm đủ, bước tiếp theo là giảm nhu cầu nền:

1. Review `minReplicas` của các service ít traffic.
2. Review memory/CPU requests thực tế so với usage.
3. Kiểm tra PDB/topology spread có đang bắt pod phân tán quá rộng không.
4. Ưu tiên giảm requests/minReplicas cho service stateless ít rủi ro trước, không đụng database/observability critical.

Lý do không chọn bước này làm đầu tiên:

* Giảm `minReplicas` hoặc requests tác động trực tiếp tới app capacity/SLO.
* Cần thêm quan sát usage theo thời gian để tránh under-provisioning.
* Blocker hiện tại đã có bằng chứng rất rõ từ Karpenter event, nên nên xử lý feature gate trước.

## Phương án vận hành tạm thời nếu cần giảm node ngay

Nếu cần giảm chi phí tức thời trước khi merge IaC, có thể làm thủ công rất thận trọng:

1. Chọn node ít requests nhất, hiện là `ip-10-0-46-8`.
2. Cordon node.
3. Drain node với PDB được tôn trọng.
4. Quan sát pod có reschedule ổn không.
5. Chỉ sau khi hệ thống ổn mới xóa node/nodeclaim hoặc để Karpenter xử lý instance.

Không nên xóa hàng loạt 4 Spot node cùng lúc, vì có service stateless đang chạy thật trên các node này và một node đang có memory requests tới 92%.

## Lệnh kiểm chứng sau khi xử lý

Kiểm tra feature gate:

```bash
kubectl -n kube-system get deploy karpenter -o yaml | rg -n "FEATURE_GATES|SpotToSpotConsolidation" -C 3
```

Kiểm tra event còn bị chặn không:

```bash
kubectl get events -A --field-selector reason=Unconsolidatable --sort-by=.lastTimestamp
```

Kiểm tra node/nodeclaim giảm:

```bash
kubectl get nodes -o wide
kubectl get nodeclaims,nodepools -A -o wide
```

Kiểm tra workload vẫn ổn:

```bash
kubectl -n techx-corp-prod get hpa,deploy,pods -o wide
kubectl get pods -A --field-selector=status.phase=Pending -o wide
kubectl top nodes
kubectl -n techx-corp-prod top pods
```

## Kết luận

Số lượng 6 node hiện tại là trạng thái dư capacity sau scale/rollout trước đó, không phải do traffic live. Karpenter đã dọn được các node empty/underutilized đơn giản, nhưng 4 Spot node còn lại cần Spot-to-Spot replacement để gom tiếp. Vì `SpotToSpotConsolidation=false`, Karpenter bị chặn và phát event `Unconsolidatable`.

Phương án tối ưu là:

1. Giữ `consolidateAfter=0s` theo latest main để reclaim nhanh.
2. Bật `SpotToSpotConsolidation=true` bằng IaC cho Karpenter controller.
3. Sau khi Karpenter có quyền repack, quan sát node count và chỉ tối ưu `minReplicas`/requests nếu vẫn còn dư capacity.

Cách này giữ tác động tới khách hàng nhỏ nhất vì vẫn giữ HPA/Karpenter hoạt động, để Karpenter tự chọn kế hoạch disruption theo PDB và NodePool budget, thay vì scale down hoặc xóa node thủ công một cách thô.
