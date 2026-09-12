# PrizmX-Kit

Bridge between **PrizmX-Foundation** and host apps. One-way dependency:

`PrizmX-Foundation` → `PrizmXServices` → `PrizmXUIEngine` → `PrizmXUIComponents`

Import only the layer you need. Mac / iOS / Pro UIs stay in the host apps.

## Layout

Check out next to **PrizmX-Foundation** (local package path):

```
PrizmX-Kit/
PrizmX-Foundation/
SwiftTCP/              required by Foundation
```

| Product | Role |
| --- | --- |
| `PrizmXServices` | `VPNManager`, profiles, mixed-port / system proxy, node ping, traffic ledger |
| `PrizmXUIEngine` | Observation view models |
| `PrizmXUIComponents` | SwiftUI Home widgets and shared chrome |

`VPNManager.metricsChannel` defaults to `.providerMessage` (Network Extension IPC). Open-core macOS sets `.kitFile` before using `VPNManager.shared`.

Platforms: macOS 14+, iOS 17+, tvOS 17+. Swift 6.

## Develop

```bash
swift test
```

## License

[Apache License 2.0](LICENSE)
