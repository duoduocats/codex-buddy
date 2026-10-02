# 版本下载统计 / Release download counts

## 简体中文

应用不包含版本统计上报，不新增设备标识、账号追踪、分析 SDK 或统计服务器。维护者可在自己的电脑上运行：

```sh
python3 scripts/download-stats.py
python3 scripts/download-stats.py --format csv
python3 scripts/download-stats.py --format json
```

脚本只读取 GitHub 公开 Release 的 DMG `download_count`，不会被打包进应用，也不需要用户或维护者提供令牌。

**这些是下载次数，不是当前安装版本分布。** 同一用户重复下载、自动更新、安装包审计和测试都可能计数；旧版本下载后也可能已经升级。它不能识别用户，也不能计算活跃用户数或精确的版本占比。

若以后需要实际活跃版本统计，应单独征求用户同意、默认关闭，并公开所收集字段、请求频率、服务端访问日志和保存期限。不能把这类请求藏在公告或更新检查中。

## English

The app includes no version telemetry, device identifiers, account tracking, analytics SDK or statistics server. Maintainers can run the commands above on their own computer.

The script reads only public GitHub Release DMG `download_count` values. It is not bundled or executed in the app and needs no access token.

**Download counts are not the distribution of installed versions.** Repeated downloads, updates, package audits and tests may contribute. A person who downloaded an old release may already have upgraded. The numbers cannot identify people, measure active users or calculate exact active-version shares.

Any future active-version measurement needs separate, default-off consent and a clear description of fields, frequency, server access logs and retention. Such requests must not be hidden within announcement or update checks.

[GitHub Release asset documentation](https://docs.github.com/en/rest/releases/assets#get-a-release-asset)
