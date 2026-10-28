## Task
- ID: <!-- vd. GOP-09 (một PR = một task; tên nhánh `<ID>-mo-ta-ngan`) -->
- Story / ADR liên quan: <!-- vd. US-070, ADR-0009 -->

## Thay đổi
<!-- Làm gì, vì sao; điểm reviewer cần chú ý; ảnh hưởng tới môi trường nào (uat/prod) -->

## Definition of Done
- [ ] CI xanh (validate/plan/lint) và đã đọc kết quả plan/render
- [ ] Không có secret, key, mật khẩu trong code, values hay log
- [ ] Thay đổi image/chart/module đã ghim phiên bản hoặc digest, không dùng `latest`
- [ ] Tài liệu/runbook liên quan đã cập nhật
- [ ] Không ghi thẳng vào `main`: PR này được review theo CODEOWNERS
