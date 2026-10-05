@IsTest
private class AccountInsightsControllerTest {

    @TestSetup
    static void setup() {
        Date today = Date.today();
        Account acc = new Account(
            Name = 'テスト商事',
            Industry = 'Technology',
            Type = 'Customer - Direct',
            Rating = 'Hot',
            AnnualRevenue = 5000000000.0,
            NumberOfEmployees = 1200,
            BillingCity = '東京都千代田区'
        );
        insert acc;
        insert new Account(Name = '空の取引先');

        List<Contact> contacts = new List<Contact>{
            new Contact(AccountId = acc.Id, LastName = '山田', FirstName = '太郎', Title = '情報システム部長'),
            new Contact(AccountId = acc.Id, LastName = 'Smith', FirstName = 'John', Title = 'CTO'),
            new Contact(AccountId = acc.Id, LastName = '佐藤')
        };
        insert contacts;

        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(AccountId = acc.Id, Name = 'クロージング間近', StageName = 'Negotiation/Review',
                Amount = 12000000, CloseDate = today.addDays(5), NextStep = '契約書レビュー'),
            new Opportunity(AccountId = acc.Id, Name = '期限超過', StageName = 'Qualification',
                Amount = 3000000, CloseDate = today.addDays(-4)),
            new Opportunity(AccountId = acc.Id, Name = '停滞案件', StageName = 'Proposal/Price Quote',
                Amount = 8000000, CloseDate = today.addDays(40)),
            new Opportunity(AccountId = acc.Id, Name = '受注案件', StageName = 'Closed Won',
                Amount = 9000000, CloseDate = today.addDays(-45)),
            new Opportunity(AccountId = acc.Id, Name = '失注案件', StageName = 'Closed Lost',
                Amount = 2000000, CloseDate = today.addDays(-90))
        };
        insert opps;

        List<Case> cases = new List<Case>{
            new Case(AccountId = acc.Id, Subject = 'ログインできない', Priority = 'High', Status = 'New', Origin = 'Phone'),
            new Case(AccountId = acc.Id, Subject = '請求書の再発行', Priority = 'Medium', Status = 'Working', Origin = 'Email'),
            new Case(AccountId = acc.Id, Subject = '操作方法の質問', Priority = 'Low', Status = 'New', Origin = 'Web')
        };
        insert cases;

        insert new List<Task>{
            new Task(WhatId = opps[0].Id, WhoId = contacts[0].Id, Subject = '要件ヒアリング', Status = 'Completed',
                ActivityDate = today.addDays(-3)),
            new Task(WhatId = acc.Id, Subject = '見積送付', Status = 'Not Started', ActivityDate = today.addDays(-2)),
            new Task(WhatId = opps[2].Id, Subject = '初回提案', Status = 'Completed', ActivityDate = today.addDays(-40))
        };
        insert new List<Event>{
            new Event(WhatId = acc.Id, Subject = '定例ミーティング', StartDateTime = Datetime.now().addDays(-5),
                DurationInMinutes = 60),
            new Event(WhatId = acc.Id, Subject = '経営層向けプレゼン', StartDateTime = Datetime.now().addDays(3),
                DurationInMinutes = 60)
        };
    }

    private static Account findAccount(String name) {
        return [SELECT Id FROM Account WHERE Name = :name LIMIT 1];
    }

    @IsTest
    static void summaryContainsAnalysis() {
        Account acc = findAccount('テスト商事');

        Test.startTest();
        AccountInsightsController.SummaryResult r = AccountInsightsController.getAccountSummary(acc.Id);
        Test.stopTest();

        Assert.areEqual('テスト商事', r.accountName);
        Assert.isTrue(r.healthScore >= 5 && r.healthScore <= 98, 'ヘルススコアは範囲内であること');
        Assert.isNotNull(r.healthLabel);
        Assert.isTrue(r.narrative.contains('テスト商事'), '要約に取引先名が含まれること');
        Assert.areEqual(4, r.kpis.size());
        Assert.isFalse(r.insights.isEmpty());
        Assert.isFalse(r.stageBars.isEmpty());
        Assert.areEqual(3, r.keyContacts.size());
        Assert.isFalse(r.timeline.isEmpty());
        Assert.isFalse(r.tags.isEmpty());
    }

    @IsTest
    static void nextActionsArePrioritized() {
        Account acc = findAccount('テスト商事');
        Case oldCase = [SELECT Id FROM Case WHERE Subject = '請求書の再発行' LIMIT 1];
        Test.setCreatedDate(oldCase.Id, Datetime.now().addDays(-10));

        Test.startTest();
        AccountInsightsController.NextActionResult r = AccountInsightsController.getNextActions(acc.Id, 20);
        AccountInsightsController.NextActionResult limited = AccountInsightsController.getNextActions(acc.Id, 2);
        Test.stopTest();

        Assert.isFalse(r.actions.isEmpty());
        Assert.areEqual('high', r.actions[0].priority, '優先度の高い提案が先頭に来ること');
        Assert.isTrue(r.highCount > 0);
        Assert.areEqual(2, limited.actions.size());
        for (AccountInsightsController.NextAction a : r.actions) {
            Assert.isNotNull(a.dueDate);
            Assert.isNotNull(a.icon);
        }
    }

    @IsTest
    static void emptyAccountStillGetsContent() {
        Account acc = findAccount('空の取引先');

        Test.startTest();
        AccountInsightsController.SummaryResult s = AccountInsightsController.getAccountSummary(acc.Id);
        AccountInsightsController.NextActionResult r = AccountInsightsController.getNextActions(acc.Id, null);
        Test.stopTest();

        Assert.isNotNull(s.narrative);
        Assert.isFalse(s.insights.isEmpty());
        Assert.isFalse(r.actions.isEmpty(), '関連データがなくても提案が出ること');
    }

    @IsTest
    static void createsFollowUpTasks() {
        Account acc = findAccount('テスト商事');
        Opportunity opp = [SELECT Id FROM Opportunity WHERE Name = 'クロージング間近' LIMIT 1];
        Contact con = [SELECT Id FROM Contact WHERE LastName = '山田' LIMIT 1];
        String due = String.valueOf(Date.today().addDays(2));

        Test.startTest();
        Id t1 = AccountInsightsController.createFollowUpTask(acc.Id, opp.Id, '最終提案', '詳細', due, 'high');
        Id t2 = AccountInsightsController.createFollowUpTask(acc.Id, con.Id, '近況伺い', null, null, 'low');
        Id t3 = AccountInsightsController.createFollowUpTask(acc.Id, null, '定例設定', null, due, 'medium');
        Test.stopTest();

        Task opportunityTask = [SELECT WhatId, Priority, ActivityDate FROM Task WHERE Id = :t1];
        Assert.areEqual(opp.Id, opportunityTask.WhatId);
        Assert.areEqual('High', opportunityTask.Priority);
        Task contactTask = [SELECT WhatId, WhoId, Priority FROM Task WHERE Id = :t2];
        Assert.areEqual(con.Id, contactTask.WhoId);
        Assert.areEqual(acc.Id, contactTask.WhatId);
        Assert.areEqual('Low', contactTask.Priority);
        Assert.areEqual('Normal', [SELECT Priority FROM Task WHERE Id = :t3].Priority);
    }

    @IsTest
    static void invalidInputThrowsFriendlyError() {
        Boolean thrown = false;
        try {
            AccountInsightsController.getAccountSummary(null);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Assert.isTrue(thrown, 'ID 未指定時は例外になること');

        thrown = false;
        try {
            AccountInsightsController.getNextActions(null, 5);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Assert.isTrue(thrown);

        thrown = false;
        try {
            AccountInsightsController.createFollowUpTask(null, null, '', null, null, null);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Assert.isTrue(thrown);
    }

    @IsTest
    static void formatsAmountsAndDates() {
        Assert.isNotNull(AccountInsightsController.formatAmount(null));
        Assert.isNotNull(AccountInsightsController.formatAmount(500));
        Assert.isNotNull(AccountInsightsController.formatAmount(25000));
        Assert.isNotNull(AccountInsightsController.formatAmount(3500000));
        Assert.isNotNull(AccountInsightsController.formatAmount(250000000));
        Assert.areEqual('10/5(月)', AccountInsightsController.formatDate(Date.newInstance(2026, 10, 5)));
        Assert.areEqual('', AccountInsightsController.formatDate(null));
    }
}
