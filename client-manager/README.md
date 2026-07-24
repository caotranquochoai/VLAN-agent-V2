# Proxy Client Manager

Ứng dụng Go độc lập để quản lý proxy IPv6 bằng `bridge_linux`, SQLite, Local API bind LAN và dashboard Vite React.

## 1. Cấu trúc runtime

```text
client-manager/
├── bin/bridge_linux
├── data/client.db
├── data/ports.json
├── data/bridge.pid
├── data/bridge.log
└── web/dist
```

Không trỏ runtime sang thư mục dự án gốc khác. Khi chạy từ workspace này, thư mục runtime mặc định là `client-manager`.

## 2. Chuẩn bị

### 2.1. Build dashboard

Trong thư mục `client-manager/web`:

```bash
npm install
npm run build
```

Sau khi build, Go server sẽ serve dashboard từ `client-manager/web/dist`.

### 2.2. Chuẩn bị bridge binary

Đặt binary bridge Linux tại:

```text
client-manager/bin/bridge_linux
```

Trên VPS Linux cần cấp quyền chạy:

```bash
chmod +x client-manager/bin/bridge_linux
```

### 2.3. Yêu cầu VPS

- VPS Linux có IPv6 public.
- Có lệnh `ip`.
- Có lệnh `curl`.
- Nên chạy bằng quyền root hoặc user có quyền thêm/xóa IPv6 trên interface.
- Firewall mở port dashboard và dải port proxy sẽ tạo.

## 3. Lệnh Go

Chạy từ thư mục `client-manager`:

```bash
go run ./cmd/proxy-client-manager init
go run ./cmd/proxy-client-manager serve --host 0.0.0.0 --port 8090
go run ./cmd/proxy-client-manager doctor
go run ./cmd/proxy-client-manager diagnostics
```

Có thể khóa rõ runtime root để mọi lệnh và systemd luôn dùng cùng SQLite:

```bash
./proxy-client-manager --root /opt/client-manager serve --host 0.0.0.0 --port 8090
./proxy-client-manager --root /opt/client-manager admin-token status
```

Cũng có thể đặt `CLIENT_MANAGER_ROOT=/opt/client-manager`. Thứ tự ưu tiên là `--root`, biến môi trường, sau đó mới đến hành vi working directory cũ để tương thích các bản đang chạy.

Khi chạy `serve` lần đầu, có 2 cách đăng nhập dashboard:

- Khuyến nghị: mở dashboard từ máy trong LAN, màn hình **Thiết lập lần đầu** sẽ cho bạn tự đặt mật khẩu admin (tối thiểu 8 ký tự). Không cần đọc log.
- Hoặc dùng admin token ngẫu nhiên được in ra terminal/log khi khởi động.

Sau khi đã đặt mật khẩu/đăng nhập lần đầu, màn hình thiết lập sẽ không hiện lại; muốn đổi token vào tab Cài đặt.

Ví dụ:

```bash
go run ./cmd/proxy-client-manager serve --host 0.0.0.0 --port 8090
```

Dashboard:

```text
http://SERVER_LAN_IP:8090
```

## 4. License LAN Agent

Client-manager hiện yêu cầu key LAN Agent để tạo proxy và start/restart Bridge.

Quy trình:

1. Mua key trong tab LAN Agent trên `proxyv3`.
2. Mở dashboard client-manager.
3. Vào tab License.
4. Nhập key LAN Agent.
5. Bấm Kích hoạt.
6. Nếu trạng thái active, có thể tạo proxy và chạy Bridge.

License server mặc định:

```text
https://v3proxy.vivucloud.com
```

URL này được cấu hình cố định ở backend client-manager, UI không hiển thị để người dùng chỉ cần nhập key.

## 5. Dashboard

Các tab chính:

- Tổng quan: trạng thái nhanh proxy, Bridge, IPv6, license.
- License: nhập key LAN Agent, kích hoạt, kiểm tra lại, gỡ máy.
- Proxy: tạo/sửa/xóa/bật/tắt/đổi IPv6/export proxy.
- Kiểm tra: kiểm tra OS, quyền root, lệnh `ip`, lệnh `curl`, bridge binary, IPv6/subnet.
- Bridge: start/stop/restart Bridge, xem/xóa log.
- Cài đặt: đổi admin token đăng nhập dashboard.

## 6. Đổi admin token

Vào tab Cài đặt trên dashboard:

1. Nhập admin token hiện tại.
2. Nhập admin token mới.
3. Nhập lại token mới để xác nhận.
4. Bấm Đổi admin token.

Sau khi đổi thành công, dashboard sẽ lưu token mới vào localStorage và token cũ không còn đăng nhập được.

Khuyến nghị token mới:

- Tối thiểu 16 ký tự.
- Nên dùng chuỗi dài ngẫu nhiên.
- Không dùng lại password cá nhân.

### Khôi phục token bằng CLI

Nếu dashboard trả về 401 và không thể đăng nhập, người có quyền truy cập trực tiếp VPS có thể đặt lại token mà không cần token cũ:

```bash
cd /opt/client-manager
./proxy-client-manager admin-token reset
```

Lệnh sẽ yêu cầu nhập token mới hai lần và ẩn ký tự khi gõ. Với automation hoặc secret manager, truyền token qua standard input:

```bash
printf '%s\n' "$NEW_ADMIN_TOKEN" | ./proxy-client-manager admin-token reset --stdin
```

Không truyền token trực tiếp trong command line để tránh lộ qua shell history hoặc danh sách process. Token mới phải có ít nhất 16 ký tự; token cũ mất hiệu lực ngay sau khi reset.

## 7. API LAN

Mặc định:

```text
http://SERVER_LAN_IP:8090
```

Các API nhạy cảm cần header:

```text
Authorization: Bearer ADMIN_TOKEN
```

API license local:

```text
GET  /api/license/status
POST /api/license/activate
POST /api/license/check
POST /api/license/deactivate
```

API đổi admin token:

```text
POST /api/auth/change-token
```

API thiết lập lần đầu và test proxy (không cần token với setup khi còn pending):

```text
GET  /api/auth/setup-status
POST /api/auth/setup
POST /api/proxies/test
```

`POST /api/proxies/test` body `{"ids":[...]}` (rỗng = test tất cả), trả về từng proxy sống/chết kèm IP thoát và độ trễ.

Export hỗ trợ các format: `ip_port`, `ip_port_auth`, `auth_ip_port`, `scheme`.

Body đổi token:

```json
{
  "current_token": "TOKEN_HIEN_TAI",
  "new_token": "TOKEN_MOI_TOI_THIEU_16_KY_TU"
}
```

## 8. Gợi ý systemd

Ví dụ service:

```ini
[Unit]
Description=LAN Proxy Client Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/client-manager
ExecStart=/opt/client-manager/proxy-client-manager serve --host 0.0.0.0 --port 8090
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

Sau khi tạo service:

```bash
systemctl daemon-reload
systemctl enable lan-proxy-client-manager
systemctl start lan-proxy-client-manager
systemctl status lan-proxy-client-manager
```

## 9. Build/release production

Trên máy build Windows có PowerShell:

```powershell
.\scripts\build-release.ps1 -Version 0.1.0
```

Script sẽ:

- Build dashboard `web/dist`.
- Build binary Linux amd64 `proxy-client-manager` với `-trimpath -ldflags "-s -w"`.
- Copy `web/dist`, `README.md`, `bin/bridge_linux` nếu có.
- Tạo gói zip trong `dist-release`.

Kết quả mẫu:

```text
client-manager/dist-release/client-manager-0.1.0-linux-amd64.zip
```

Sau khi upload lên VPS Linux:

```bash
unzip client-manager-0.1.0-linux-amd64.zip -d /opt/client-manager
cd /opt/client-manager
chmod +x proxy-client-manager bin/bridge_linux install.sh
./proxy-client-manager serve --host 0.0.0.0 --port 8090
```

## 10. Kiểm tra nhanh sau cài đặt

1. Mở dashboard và đăng nhập bằng admin token.
2. Vào License nhập key LAN Agent và kích hoạt.
3. Vào Kiểm tra để xác nhận IPv6/subnet OK.
4. Vào Proxy tạo thử 1 proxy.
5. Vào Bridge bấm Start.
6. Export proxy hoặc kiểm tra kết nối từ máy khác trong LAN.
