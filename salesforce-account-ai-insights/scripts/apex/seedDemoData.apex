// デモ用サンプルデータを作成する匿名 Apex。
// 開発者コンソール > Debug > Open Execute Anonymous Window に貼り付けて実行するか、
// sf apex run --file scripts/apex/seedDemoData.apex で実行してください。
// 何度実行しても同名の取引先と関連データを作り直します。

String accountName = '株式会社ミライテック（デモ）';
Date today = Date.today();
Datetime now = Datetime.now();

List<Account> existing = [SELECT Id FROM Account WHERE Name = :accountName];
if (!existing.isEmpty()) {
    delete [SELECT Id FROM Task WHERE AccountId IN :existing];
    delete [SELECT Id FROM Event WHERE AccountId IN :existing];
    delete [SELECT Id FROM Case WHERE AccountId IN :existing];
    delete [SELECT Id FROM Opportunity WHERE AccountId IN :existing];
    delete [SELECT Id FROM Contact WHERE AccountId IN :existing];
    delete existing;
}

Account acc = new Account(
    Name = accountName,
    Industry = 'Technology',
    Type = 'Customer - Direct',
    Rating = 'Hot',
    AnnualRevenue = 18000000000.0,
    NumberOfEmployees = 2400,
    BillingState = '東京都',
    BillingCity = '港区',
    Website = 'https://example.com',
    Phone = '03-0000-0000'
);
insert acc;

List<Contact> contacts = new List<Contact>{
    new Contact(AccountId = acc.Id, LastName = '高橋', FirstName = '誠', Title = '執行役員 CIO', Email = 'takahashi@example.com'),
    new Contact(AccountId = acc.Id, LastName = '鈴木', FirstName = '彩', Title = '情報システム部 部長', Email = 'suzuki@example.com'),
    new Contact(AccountId = acc.Id, LastName = '田中', FirstName = '健一', Title = '経営企画部 課長', Email = 'tanaka@example.com'),
    new Contact(AccountId = acc.Id, LastName = '伊藤', FirstName = '直子', Title = '購買部 マネージャー', Email = 'ito@example.com')
};
insert contacts;

List<Opportunity> opps = new List<Opportunity>{
    // 0: クロージング間近（高確度）
    new Opportunity(AccountId = acc.Id, Name = '全社 CRM 刷新プロジェクト', StageName = 'Negotiation/Review',
        Amount = 48000000, CloseDate = today.addDays(9), NextStep = '法務による契約書レビュー'),
    // 1: 完了予定日超過
    new Opportunity(AccountId = acc.Id, Name = 'データ分析基盤 PoC', StageName = 'Qualification',
        Amount = 6500000, CloseDate = today.addDays(-6)),
    // 2: 停滞（最終活動 40 日前）
    new Opportunity(AccountId = acc.Id, Name = 'コールセンター AI 導入', StageName = 'Proposal/Price Quote',
        Amount = 22000000, CloseDate = today.addDays(45)),
    // 3: 進行中（順調）
    new Opportunity(AccountId = acc.Id, Name = '営業支援モバイルアプリ', StageName = 'Needs Analysis',
        Amount = 12000000, CloseDate = today.addDays(70)),
    // 4: 受注（アップセル候補）
    new Opportunity(AccountId = acc.Id, Name = 'マーケティングオートメーション導入', StageName = 'Closed Won',
        Amount = 18000000, CloseDate = today.addDays(-60)),
    // 5: 受注
    new Opportunity(AccountId = acc.Id, Name = 'サポートポータル構築', StageName = 'Closed Won',
        Amount = 9500000, CloseDate = today.addDays(-150)),
    // 6: 失注
    new Opportunity(AccountId = acc.Id, Name = '旧システム保守延長', StageName = 'Closed Lost',
        Amount = 4000000, CloseDate = today.addDays(-110))
};
insert opps;

insert new List<Case>{
    new Case(AccountId = acc.Id, ContactId = contacts[1].Id, Subject = '本番環境でレポートが表示されない',
        Priority = 'High', Status = 'Escalated', Origin = 'Phone'),
    new Case(AccountId = acc.Id, ContactId = contacts[3].Id, Subject = '請求書の宛名変更について',
        Priority = 'Medium', Status = 'Working', Origin = 'Email'),
    new Case(AccountId = acc.Id, ContactId = contacts[2].Id, Subject = 'ダッシュボードの共有設定の質問',
        Priority = 'Low', Status = 'Closed', Origin = 'Web')
};

insert new List<Task>{
    new Task(WhatId = opps[0].Id, WhoId = contacts[0].Id, Subject = '最終見積の提示', Status = 'Completed',
        Priority = 'High', ActivityDate = today.addDays(-2)),
    new Task(WhatId = opps[0].Id, WhoId = contacts[1].Id, Subject = '導入スケジュールの確認電話', Status = 'Completed',
        Priority = 'Normal', ActivityDate = today.addDays(-6)),
    new Task(WhatId = opps[3].Id, WhoId = contacts[2].Id, Subject = '要件ヒアリング議事録の送付', Status = 'Completed',
        Priority = 'Normal', ActivityDate = today.addDays(-12)),
    new Task(WhatId = opps[2].Id, WhoId = contacts[1].Id, Subject = '提案書の送付', Status = 'Completed',
        Priority = 'Normal', ActivityDate = today.addDays(-40)),
    new Task(WhatId = acc.Id, WhoId = contacts[3].Id, Subject = '購買部へ見積条件の回答', Status = 'Not Started',
        Priority = 'High', ActivityDate = today.addDays(-3))
};

insert new List<Event>{
    new Event(WhatId = opps[0].Id, WhoId = contacts[0].Id, Subject = '経営層向け最終プレゼン',
        StartDateTime = now.addDays(3), DurationInMinutes = 60, Location = 'ミライテック本社'),
    new Event(WhatId = acc.Id, WhoId = contacts[1].Id, Subject = '月次定例ミーティング',
        StartDateTime = now.addDays(-8), DurationInMinutes = 60),
    new Event(WhatId = opps[1].Id, WhoId = contacts[2].Id, Subject = 'PoC キックオフ',
        StartDateTime = now.addDays(-20), DurationInMinutes = 90)
};

System.debug('デモデータを作成しました: /lightning/r/Account/' + acc.Id + '/view');
