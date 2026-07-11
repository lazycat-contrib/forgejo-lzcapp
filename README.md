# forgejo-lzcapp

每天 23:00 UTC 检查 `forgejoclone/forgejo` 的稳定版本。发现更新后自动复制 `linux/amd64` 镜像、构建版本化 LPK、创建 GitHub Release，并提交懒猫官方商店和喵喵私有商店。

GitHub Secrets：官方商店使用 `LAZYCAT_TOKEN`（或兼容凭据）；喵喵商店使用 `APPSTORE_URL`、`APPSTORE_TOKEN`，可选 `APP_ID` 和 `PRIVATE_STORE_GROUP_CODES`。
