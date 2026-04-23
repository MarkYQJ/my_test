# my_test

GitHub <-> GitLab 雙向同步專案。透過 GitLab CI 定時排程，自動偵測兩端 `main` branch 的差異，並以 PR/MR 方式提交變更供人工審核。

## 架構概覽

```
┌──────────┐     scheduled CI      ┌──────────┐
│  GitLab  │ ───────────────────── │  GitHub  │
│  (main)  │                       │  (main)  │
└────┬─────┘                       └────┬─────┘
     │          bidirectional-sync.sh   │
     │  1. fetch both remotes           │
     │  2. compare SHA                  │
     │  3. detect sync direction        │
     │                                  │
     │  ┌─────────────────────────┐     │
     ├──│ sync/github-to-gitlab   │──>  MR
     │  └─────────────────────────┘     │
     │  ┌─────────────────────────┐     │
     MR <──│ sync/gitlab-to-github │──┤
            └─────────────────────────┘
```

## 設計思路

### 為什麼用 PR/MR 而不是直接推送？

最初設計是直接 merge + push，但這有風險：

- 自動 merge 可能引入衝突或錯誤，直接推到 `main` 會影響所有人
- 無法在合併前執行 CI 驗證（測試、lint 等）
- 缺少人工審核機制，違反 protected branch 的最佳實踐

改為 PR/MR 模式後：
- 變更透過 `sync/*` branch 提交，由團隊成員審核後合併
- 可在 PR/MR 中看到完整 diff，確認變更內容
- 可搭配 CI pipeline 自動跑測試，確保品質

### 同步方向偵測

腳本使用 `git merge-base --is-ancestor` 判斷三種情況：

| 狀態 | 條件 | 動作 |
|------|------|------|
| 兩端一致 | `gh_sha == gl_sha` | 不做任何事 |
| GitLab 領先 | GitHub SHA 是 GitLab SHA 的祖先 | 建立 GitHub PR (`sync/gitlab-to-github`) |
| GitHub 領先 | GitLab SHA 是 GitHub SHA 的祖先 | 建立 GitLab MR (`sync/github-to-gitlab`) |
| 兩端分岔 | 互不為祖先 | 同時建立 PR 和 MR |

### Sync Branch 策略

- 固定使用 `sync/gitlab-to-github` 和 `sync/github-to-gitlab` 兩個 branch 名稱
- 每次同步時 force-push 更新 sync branch，確保 PR/MR 反映最新狀態
- 建立 PR/MR 前先檢查是否已有 open 的 PR/MR，避免重複建立
- 若已存在 PR/MR，force-push 會自動更新其內容

### Tag 同步

Tag 採用**直接推送**，不走 PR/MR：

- 列出兩端所有 tag，比對差異
- 將對方沒有的 tag 直接 push 過去
- Tag 通常是 immutable 的版本標記，直接同步風險較低

### 安全性考量

- **Token 遮罩**：所有 git 操作的輸出都經過 `mask_credentials()` 處理，避免 token 洩漏到 CI log
- **參數驗證**：腳本啟動時檢查所有 7 個必要參數，缺少則立即失敗
- **API Token 預檢**：正式操作前先用 API 確認 token 有效且有權限存取對應 repo
- **Token 透過 CI Variables 注入**：`GITHUB_TOKEN` 和 `GITLAB_TOKEN` 由 GitLab CI 的 protected variables 管理，不寫在程式碼中

### 錯誤處理

- `set -e`：任何指令失敗立即中止
- `trap cleanup EXIT`：確保暫存目錄和檔案在腳本結束時清理
- **Partial Failure 追蹤**：部分操作失敗時標記為 `partial_failure`，最終以非零 exit code 退出，讓 CI pipeline 正確反映失敗狀態
- Branch fetch 失敗時優雅退出（可能是新 repo 尚未有 main branch）

## CI 配置

```yaml
bidirectional_sync:
  only:
    - schedules    # 僅由排程觸發，不會在每次 push 時執行
  tags:
    - cloudinfra-setup-global-arm  # 指定 runner
```

### 必要的 CI Variables

| Variable | 說明 |
|----------|------|
| `GITHUB_TOKEN` | GitHub Personal Access Token，需有 repo 和 PR 建立權限 |
| `GITLAB_TOKEN` | GitLab Personal Access Token，需有 project read/write 和 MR 建立權限 |

### 腳本參數

```
scripts/bidirectional-sync.sh \
  <github_url>         # GitHub repo URL（含 token）
  <gitlab_url>         # GitLab repo URL（含 token）
  <github_api_token>   # GitHub API Token
  <gitlab_api_token>   # GitLab API Token
  <github_repo>        # GitHub repo（格式：owner/repo）
  <gitlab_project_id>  # GitLab project ID
  <gitlab_base_url>    # GitLab 實例 URL
```

## 已知限制

- 僅同步 `main` branch（hardcoded）
- Tag 衝突（同名但不同 SHA）不會處理
- 兩端分岔時需要人工解決衝突後才能合併 PR/MR
- 排程間隔內的多次 push 會被合併成一次同步