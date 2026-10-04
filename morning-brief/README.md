# Morning Intel Brief

毎朝、指定トピックの最新動向を収集し、トピック別に要約・ポイント・参照元を並べる個人用ページです。

- ページ: https://claude.ai/artifact/ARXDMrwKcrXEvTkcbSFuaE（`index.html` を Artifact として公開）
- データ: ページのデータベースに保存
  - `config/topics`: 収集トピック（ページの「トピック設定」から編集可能）
  - `briefs/<YYYY-MM-DD>`: その日のブリーフ
- 収集: Claude Code のルーティン「Morning Intel Brief（毎朝の情報収集）」が毎日 6:40（日本時間）に新しいセッションで実行します。指示文は `routine-prompt.md` です。
