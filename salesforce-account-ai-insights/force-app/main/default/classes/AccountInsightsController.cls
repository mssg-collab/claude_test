/**
 * 取引先レコードページ用「AI 取引先サマリー」「AI ネクストアクション」のデータ提供クラス。
 *
 * デモ用途のため外部 AI サービスとは連携せず、取引先に紐づく商談・ケース・取引先責任者・
 * 活動（ToDo / 行動）をルールベースで分析し、AI が生成したような文章と提案を組み立てる。
 */
public with sharing class AccountInsightsController {

    private static final Integer RECENT_DAYS = 30;
    private static final Integer CLOSING_SOON_DAYS = 14;
    private static final Integer STALE_OPP_DAYS = 21;
    private static final Integer DORMANT_CONTACT_DAYS = 90;
    private static final Integer OLD_CASE_DAYS = 7;
    private static final List<String> WEEKDAYS = new List<String>{ '日', '月', '火', '水', '木', '金', '土' };
    private static final Map<String, String> ACTION_ICONS = new Map<String, String>{
        'call' => 'utility:call',
        'email' => 'utility:email',
        'meeting' => 'utility:event',
        'task' => 'utility:task'
    };
    private static final Map<String, String> ACTION_LABELS = new Map<String, String>{
        'call' => '電話',
        'email' => 'メール',
        'meeting' => '打ち合わせ',
        'task' => 'タスク'
    };

    // ------------------------------------------------------------------
    // Public API
    // ------------------------------------------------------------------

    @AuraEnabled
    public static SummaryResult getAccountSummary(Id accountId) {
        try {
            return buildSummary(loadData(accountId));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw newAuraException(e.getMessage());
        }
    }

    @AuraEnabled
    public static NextActionResult getNextActions(Id accountId, Integer maxActions) {
        try {
            DataSet d = loadData(accountId);
            List<NextAction> candidates = buildActions(d);
            candidates.sort();

            Integer limitCount = (maxActions == null || maxActions <= 0) ? 6 : maxActions;
            List<NextAction> selected = new List<NextAction>();
            for (NextAction a : candidates) {
                if (selected.size() >= limitCount) {
                    break;
                }
                selected.add(a);
            }
            return new NextActionResult(selected, candidates.size(), d.recordCount(), d.now.format('yyyy/MM/dd HH:mm'));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw newAuraException(e.getMessage());
        }
    }

    /**
     * ネクストアクションから ToDo を作成する。関連レコードが取引先責任者の場合は名前（WhoId）に、
     * それ以外（商談・ケースなど）は関連先（WhatId）に設定する。
     */
    @AuraEnabled
    public static Id createFollowUpTask(
        Id accountId,
        Id relatedId,
        String subject,
        String description,
        String dueDate,
        String priority
    ) {
        try {
            if (accountId == null || String.isBlank(subject)) {
                throw newAuraException('ToDo の作成に必要な情報が不足しています。');
            }
            Task t = new Task(
                Subject = subject.abbreviate(255),
                Description = description,
                ActivityDate = String.isBlank(dueDate) ? null : Date.valueOf(dueDate),
                Priority = priority == 'high' ? 'High' : (priority == 'low' ? 'Low' : 'Normal'),
                OwnerId = UserInfo.getUserId(),
                WhatId = accountId
            );
            if (relatedId != null) {
                Schema.SObjectType relatedType = relatedId.getSobjectType();
                if (relatedType == Contact.SObjectType) {
                    t.WhoId = relatedId;
                } else if (relatedType != Task.SObjectType && relatedType != Event.SObjectType) {
                    t.WhatId = relatedId;
                }
            }
            insert as user t;
            return t.Id;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw newAuraException('ToDo を作成できませんでした: ' + e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // Data loading & analysis
    // ------------------------------------------------------------------

    private class DataSet {
        Account account;
        List<Opportunity> opportunities;
        List<Case> cases;
        List<Contact> contacts;
        List<Task> tasks;
        List<Event> events;
        Date today = Date.today();
        Datetime now = Datetime.now();

        List<Opportunity> openOpps = new List<Opportunity>();
        List<Opportunity> wonOpps = new List<Opportunity>();
        List<Opportunity> lostOpps = new List<Opportunity>();
        List<Opportunity> overdueOpps = new List<Opportunity>();
        List<Opportunity> closingSoonOpps = new List<Opportunity>();
        List<Opportunity> staleOpps = new List<Opportunity>();
        List<Case> openCases = new List<Case>();
        List<Case> highCases = new List<Case>();
        List<Task> overdueTasks = new List<Task>();
        List<Event> upcomingEvents = new List<Event>();
        Event nextEvent;
        Opportunity topOpenOpp;
        Integer recentActivityCount = 0;
        Date lastActivityDate;
        Decimal pipelineAmount = 0;
        Decimal weightedAmount = 0;
        Decimal wonAmount = 0;

        Integer recordCount() {
            return 1 + opportunities.size() + cases.size() + contacts.size() + tasks.size() + events.size();
        }

        Integer daysSinceLastActivity() {
            return lastActivityDate == null ? null : lastActivityDate.daysBetween(today);
        }
    }

    private static DataSet loadData(Id accountId) {
        if (accountId == null) {
            throw newAuraException('取引先 ID が指定されていません。');
        }
        List<Account> accounts = [
            SELECT Id, Name, Industry, Type, Rating, Website, AnnualRevenue, NumberOfEmployees,
                BillingState, BillingCity, Owner.Name
            FROM Account
            WHERE Id = :accountId
            WITH USER_MODE
            LIMIT 1
        ];
        if (accounts.isEmpty()) {
            throw newAuraException('取引先が見つからないか、参照する権限がありません。');
        }

        DataSet d = new DataSet();
        d.account = accounts[0];
        d.opportunities = [
            SELECT Id, Name, StageName, Amount, CloseDate, Probability, IsClosed, IsWon,
                LastActivityDate, NextStep, CreatedDate
            FROM Opportunity
            WHERE AccountId = :accountId
            WITH USER_MODE
            ORDER BY CloseDate DESC
            LIMIT 200
        ];
        d.cases = [
            SELECT Id, CaseNumber, Subject, Status, Priority, IsClosed, CreatedDate
            FROM Case
            WHERE AccountId = :accountId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 200
        ];
        d.contacts = [
            SELECT Id, Name, FirstName, LastName, Title, Email, LastActivityDate
            FROM Contact
            WHERE AccountId = :accountId
            WITH USER_MODE
            ORDER BY LastActivityDate DESC NULLS LAST, CreatedDate ASC
            LIMIT 200
        ];
        d.tasks = [
            SELECT Id, Subject, ActivityDate, Status, IsClosed, Priority, CreatedDate, What.Name, Who.Name
            FROM Task
            WHERE AccountId = :accountId
            WITH USER_MODE
            ORDER BY ActivityDate DESC NULLS LAST
            LIMIT 100
        ];
        d.events = [
            SELECT Id, Subject, StartDateTime, What.Name, Who.Name
            FROM Event
            WHERE AccountId = :accountId
            WITH USER_MODE
            ORDER BY StartDateTime DESC
            LIMIT 100
        ];
        analyze(d);
        return d;
    }

    private static void analyze(DataSet d) {
        Date yearAgo = d.today.addDays(-365);
        for (Opportunity o : d.opportunities) {
            Decimal amount = o.Amount == null ? 0 : o.Amount;
            if (!o.IsClosed) {
                d.openOpps.add(o);
                d.pipelineAmount += amount;
                d.weightedAmount += amount * (o.Probability == null ? 0 : o.Probability) / 100;
                if (d.topOpenOpp == null || amount > nvl(d.topOpenOpp.Amount)) {
                    d.topOpenOpp = o;
                }
                if (o.CloseDate != null && o.CloseDate < d.today) {
                    d.overdueOpps.add(o);
                } else if (o.CloseDate != null && o.CloseDate <= d.today.addDays(CLOSING_SOON_DAYS)) {
                    d.closingSoonOpps.add(o);
                }
                if (o.LastActivityDate == null || o.LastActivityDate.daysBetween(d.today) >= STALE_OPP_DAYS) {
                    d.staleOpps.add(o);
                }
            } else if (o.CloseDate != null && o.CloseDate >= yearAgo) {
                if (o.IsWon) {
                    d.wonOpps.add(o);
                    d.wonAmount += amount;
                } else {
                    d.lostOpps.add(o);
                }
            }
        }

        for (Case c : d.cases) {
            if (!c.IsClosed) {
                d.openCases.add(c);
                if (c.Priority == 'High') {
                    d.highCases.add(c);
                }
            }
        }

        for (Task t : d.tasks) {
            if (!t.IsClosed && t.ActivityDate != null && t.ActivityDate < d.today) {
                d.overdueTasks.add(t);
            }
            if (t.IsClosed) {
                registerActivity(d, t.ActivityDate != null ? t.ActivityDate : t.CreatedDate.date());
            }
        }

        for (Event e : d.events) {
            if (e.StartDateTime == null) {
                continue;
            }
            if (e.StartDateTime >= d.now) {
                d.upcomingEvents.add(e);
                if (d.nextEvent == null || e.StartDateTime < d.nextEvent.StartDateTime) {
                    d.nextEvent = e;
                }
            } else {
                registerActivity(d, e.StartDateTime.date());
            }
        }
    }

    private static void registerActivity(DataSet d, Date activityDate) {
        if (activityDate == null || activityDate > d.today) {
            return;
        }
        if (d.lastActivityDate == null || activityDate > d.lastActivityDate) {
            d.lastActivityDate = activityDate;
        }
        if (activityDate >= d.today.addDays(-RECENT_DAYS)) {
            d.recentActivityCount++;
        }
    }

    private static Integer calculateHealthScore(DataSet d) {
        Integer score = 55;
        if (!d.openOpps.isEmpty()) {
            score += 10;
        }
        if (!d.wonOpps.isEmpty()) {
            score += 10;
        }
        Integer winRate = winRate(d);
        if (winRate != null && winRate >= 50) {
            score += 5;
        }
        if (d.recentActivityCount >= 3) {
            score += 10;
        } else if (d.recentActivityCount >= 1) {
            score += 5;
        } else {
            score -= 10;
        }
        Integer idle = d.daysSinceLastActivity();
        if (idle == null || idle > 60) {
            score -= 10;
        }
        if (!d.upcomingEvents.isEmpty()) {
            score += 5;
        }
        score -= d.highCases.size() * 8;
        score -= (d.openCases.size() - d.highCases.size()) * 3;
        score -= d.overdueTasks.size() * 4;
        score -= d.overdueOpps.size() * 5;
        return Math.max(5, Math.min(98, score));
    }

    private static Integer winRate(DataSet d) {
        Integer closed = d.wonOpps.size() + d.lostOpps.size();
        if (closed == 0) {
            return null;
        }
        return Math.round(d.wonOpps.size() * 100.0 / closed);
    }

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------

    public class SummaryResult {
        @AuraEnabled public String accountName;
        @AuraEnabled public String profileLine;
        @AuraEnabled public String ownerName;
        @AuraEnabled public Integer healthScore;
        @AuraEnabled public String healthLabel;
        @AuraEnabled public String healthTone;
        @AuraEnabled public String headline;
        @AuraEnabled public String narrative;
        @AuraEnabled public List<String> tags = new List<String>();
        @AuraEnabled public List<Kpi> kpis = new List<Kpi>();
        @AuraEnabled public List<Insight> insights = new List<Insight>();
        @AuraEnabled public List<StageBar> stageBars = new List<StageBar>();
        @AuraEnabled public List<ContactInfo> keyContacts = new List<ContactInfo>();
        @AuraEnabled public List<TimelineEntry> timeline = new List<TimelineEntry>();
        @AuraEnabled public Integer analyzedRecords;
        @AuraEnabled public String generatedAtLabel;
    }

    public class Kpi {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public String subText;
        @AuraEnabled public String icon;
        @AuraEnabled public String tone;

        public Kpi(String key, String label, String value, String subText, String icon, String tone) {
            this.key = key;
            this.label = label;
            this.value = value;
            this.subText = subText;
            this.icon = icon;
            this.tone = tone;
        }
    }

    public class Insight {
        @AuraEnabled public String key;
        @AuraEnabled public String kind;
        @AuraEnabled public String title;
        @AuraEnabled public String detail;
        @AuraEnabled public String icon;

        public Insight(String key, String kind, String title, String detail) {
            this.key = key;
            this.kind = kind;
            this.title = title;
            this.detail = detail;
            this.icon = kind == 'positive' ? 'utility:success' : (kind == 'risk' ? 'utility:warning' : 'utility:info');
        }
    }

    public class StageBar implements Comparable {
        @AuraEnabled public String stage;
        @AuraEnabled public Integer count = 0;
        @AuraEnabled public String amountLabel;
        @AuraEnabled public Integer percent;
        Decimal amount = 0;
        Decimal probability = 0;

        public Integer compareTo(Object other) {
            StageBar o = (StageBar) other;
            if (probability == o.probability) {
                return 0;
            }
            return probability < o.probability ? -1 : 1;
        }
    }

    public class ContactInfo {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String title;
        @AuraEnabled public String initials;
        @AuraEnabled public String lastTouchLabel;
        @AuraEnabled public Boolean isDormant;
    }

    public class TimelineEntry implements Comparable {
        @AuraEnabled public String id;
        @AuraEnabled public String kind;
        @AuraEnabled public String title;
        @AuraEnabled public String subtitle;
        @AuraEnabled public String dateLabel;
        @AuraEnabled public String icon;
        Datetime sortKey;

        public TimelineEntry(String id, String kind, String title, String subtitle, Datetime sortKey, String icon) {
            this.id = id;
            this.kind = kind;
            this.title = title;
            this.subtitle = subtitle;
            this.sortKey = sortKey;
            this.icon = icon;
            this.dateLabel = AccountInsightsController.formatDate(sortKey.date());
        }

        public Integer compareTo(Object other) {
            TimelineEntry o = (TimelineEntry) other;
            if (sortKey == o.sortKey) {
                return 0;
            }
            return sortKey > o.sortKey ? -1 : 1;
        }
    }

    private static SummaryResult buildSummary(DataSet d) {
        SummaryResult r = new SummaryResult();
        Account a = d.account;
        r.accountName = a.Name;
        r.ownerName = a.Owner?.Name;
        r.analyzedRecords = d.recordCount();
        r.generatedAtLabel = d.now.format('yyyy/MM/dd HH:mm');

        List<String> profile = new List<String>();
        addIfNotBlank(profile, a.Industry);
        addIfNotBlank(profile, a.Type);
        String location = (a.BillingState == null ? '' : a.BillingState) + (a.BillingCity == null ? '' : a.BillingCity);
        addIfNotBlank(profile, location);
        r.profileLine = String.join(profile, ' · ');

        r.healthScore = calculateHealthScore(d);
        if (r.healthScore >= 80) {
            r.healthLabel = '良好';
            r.healthTone = 'good';
            r.headline = '関係は良好です。進行中の商談を確実にクロージングする好機です。';
        } else if (r.healthScore >= 60) {
            r.healthLabel = '安定';
            r.healthTone = 'stable';
            r.headline = '安定した関係です。いくつかのフォローでさらなる拡大が見込めます。';
        } else if (r.healthScore >= 40) {
            r.healthLabel = '要注意';
            r.healthTone = 'caution';
            r.headline = '注意が必要です。リスク要因への早めの対応をおすすめします。';
        } else {
            r.healthLabel = 'リスク';
            r.healthTone = 'risk';
            r.headline = 'リスクが高い状態です。関係改善のアクションを至急検討してください。';
        }

        r.narrative = buildNarrative(d);
        r.tags = buildTags(d);
        r.kpis = buildKpis(d);
        r.insights = buildInsights(d);
        r.stageBars = buildStageBars(d);
        r.keyContacts = buildContacts(d);
        r.timeline = buildTimeline(d);
        return r;
    }

    private static String buildNarrative(DataSet d) {
        Account a = d.account;
        List<String> s = new List<String>();

        String profile = a.Name + 'は';
        if (String.isNotBlank(a.Industry)) {
            profile += a.Industry + '業界の';
        }
        profile += '取引先です';
        List<String> scale = new List<String>();
        if (a.NumberOfEmployees != null) {
            scale.add('従業員数 ' + a.NumberOfEmployees.format() + '名');
        }
        if (a.AnnualRevenue != null) {
            scale.add('年間売上 ' + formatAmount(a.AnnualRevenue));
        }
        if (!scale.isEmpty()) {
            profile += '（' + String.join(scale, ' / ') + '）';
        }
        s.add(profile + '。');

        if (!d.openOpps.isEmpty()) {
            String pipeline = '現在 ' + d.openOpps.size() + '件の商談が進行中で、パイプライン総額は'
                + formatAmount(d.pipelineAmount) + '（加重見込み ' + formatAmount(d.weightedAmount) + '）です。';
            Opportunity top = d.topOpenOpp;
            pipeline += '最大の案件は「' + top.Name + '」（' + top.StageName
                + (top.CloseDate == null ? '' : '、完了予定 ' + formatDate(top.CloseDate)) + '）です。';
            s.add(pipeline);
        } else {
            s.add('現在進行中の商談はありません。');
        }

        Integer rate = winRate(d);
        if (!d.wonOpps.isEmpty()) {
            s.add('直近12ヶ月で ' + d.wonOpps.size() + '件・' + formatAmount(d.wonAmount) + 'を受注しており'
                + (rate == null ? '' : '、勝率は' + rate + '%') + 'です。');
        } else if (!d.lostOpps.isEmpty()) {
            s.add('直近12ヶ月は ' + d.lostOpps.size() + '件の失注があり、受注実績はありません。');
        }

        if (!d.openCases.isEmpty()) {
            s.add('サポート面では ' + d.openCases.size() + '件のケースが未解決で、そのうち優先度「高」が '
                + d.highCases.size() + '件あります。');
        } else {
            s.add('未解決のサポートケースはなく、サポート面は安定しています。');
        }

        Integer idle = d.daysSinceLastActivity();
        if (d.recentActivityCount > 0) {
            s.add('直近30日間で ' + d.recentActivityCount + '件の活動があり、最終接点は' + relativeDays(idle) + 'です。');
        } else if (idle != null) {
            s.add('最後の接点から ' + idle + '日が経過しており、エンゲージメントの低下が懸念されます。');
        } else {
            s.add('活動履歴がまだ記録されていません。');
        }

        if (d.nextEvent != null) {
            s.add('次回の予定は ' + formatDate(d.nextEvent.StartDateTime.date()) + ' の「' + d.nextEvent.Subject + '」です。');
        }
        return String.join(s, '');
    }

    private static List<String> buildTags(DataSet d) {
        List<String> tags = new List<String>();
        if (d.account.Rating == 'Hot') {
            tags.add('#ホット取引先');
        }
        if (!d.closingSoonOpps.isEmpty()) {
            tags.add('#クロージング間近');
        }
        for (Opportunity o : d.openOpps) {
            if (o.Probability != null && o.Probability >= 70) {
                tags.add('#高確度案件あり');
                break;
            }
        }
        if (!d.wonOpps.isEmpty()) {
            tags.add('#アップセル機会');
        }
        if (!d.highCases.isEmpty()) {
            tags.add('#サポート要注意');
        }
        if (!d.staleOpps.isEmpty()) {
            tags.add('#停滞商談');
        }
        if (d.recentActivityCount == 0) {
            tags.add('#接点減少');
        }
        if (tags.isEmpty()) {
            tags.add('#関係維持');
        }
        return tags;
    }

    private static List<Kpi> buildKpis(DataSet d) {
        List<Kpi> kpis = new List<Kpi>();
        kpis.add(new Kpi(
            'pipeline', '進行中の商談', formatAmount(d.pipelineAmount),
            d.openOpps.size() + '件 · 加重 ' + formatAmount(d.weightedAmount),
            'utility:opportunity', d.openOpps.isEmpty() ? 'neutral' : 'positive'
        ));
        Integer rate = winRate(d);
        kpis.add(new Kpi(
            'won', '受注実績（12ヶ月）', formatAmount(d.wonAmount),
            d.wonOpps.size() + '件' + (rate == null ? '' : ' · 勝率 ' + rate + '%'),
            'utility:success', d.wonOpps.isEmpty() ? 'neutral' : 'positive'
        ));
        kpis.add(new Kpi(
            'cases', '未解決ケース', d.openCases.size() + '件',
            '優先度「高」 ' + d.highCases.size() + '件',
            'utility:case', !d.highCases.isEmpty() ? 'negative' : (!d.openCases.isEmpty() ? 'warning' : 'positive')
        ));
        Integer idle = d.daysSinceLastActivity();
        kpis.add(new Kpi(
            'activity', '直近30日の活動', d.recentActivityCount + '件',
            idle == null ? '活動記録なし' : '最終接点 ' + relativeDays(idle),
            'utility:date_time', d.recentActivityCount >= 3 ? 'positive' : (d.recentActivityCount > 0 ? 'neutral' : 'warning')
        ));
        return kpis;
    }

    private static List<Insight> buildInsights(DataSet d) {
        List<Insight> insights = new List<Insight>();

        Opportunity hot;
        for (Opportunity o : d.openOpps) {
            if (o.Probability != null && o.Probability >= 70 && (hot == null || nvl(o.Amount) > nvl(hot.Amount))) {
                hot = o;
            }
        }
        if (hot != null) {
            insights.add(new Insight('hot', 'positive', '高確度の商談があります',
                '「' + hot.Name + '」は確度 ' + hot.Probability.intValue() + '%・' + formatAmount(hot.Amount) + '。今期の受注が期待できます。'));
        }
        if (!d.wonOpps.isEmpty()) {
            Opportunity latest = d.wonOpps[0];
            insights.add(new Insight('won', 'positive', '直近の受注実績',
                '「' + latest.Name + '」を' + formatDate(latest.CloseDate) + 'に受注。導入効果の確認がアップセルの起点になります。'));
        }
        if (!d.highCases.isEmpty()) {
            Case c = d.highCases[0];
            insights.add(new Insight('case', 'risk', '優先度「高」のケースが ' + d.highCases.size() + '件',
                '#' + c.CaseNumber + '「' + c.Subject + '」（' + c.Status + '）。商談への影響を避けるため早期解決が必要です。'));
        }
        if (!d.overdueOpps.isEmpty()) {
            insights.add(new Insight('overdue', 'risk', '完了予定日を過ぎた商談が ' + d.overdueOpps.size() + '件',
                '「' + d.overdueOpps[0].Name + '」など。フォーキャストの精度に影響するため日付の見直しを推奨します。'));
        }
        if (!d.staleOpps.isEmpty()) {
            insights.add(new Insight('stale', 'risk', '停滞中の商談が ' + d.staleOpps.size() + '件',
                STALE_OPP_DAYS + '日以上活動のない商談があります。失注リスクの兆候です。'));
        }
        Integer dormant = 0;
        for (Contact c : d.contacts) {
            if (c.LastActivityDate == null || c.LastActivityDate.daysBetween(d.today) >= DORMANT_CONTACT_DAYS) {
                dormant++;
            }
        }
        if (!d.contacts.isEmpty() && dormant > 0) {
            insights.add(new Insight('contacts', 'info', 'キーパーソンのカバレッジ',
                '取引先責任者 ' + d.contacts.size() + '名のうち ' + dormant + '名と' + DORMANT_CONTACT_DAYS + '日以上接点がありません。'));
        }
        if (d.nextEvent != null) {
            insights.add(new Insight('event', 'info', '次回の予定',
                formatDate(d.nextEvent.StartDateTime.date()) + '「' + d.nextEvent.Subject + '」。最新状況を踏まえたアジェンダ準備を。'));
        }
        if (insights.isEmpty()) {
            insights.add(new Insight('none', 'info', '特筆すべきシグナルはありません',
                '関連データが少ないため、まずは取引先責任者・商談・活動の登録から始めましょう。'));
        }
        return insights;
    }

    private static List<StageBar> buildStageBars(DataSet d) {
        Map<String, StageBar> byStage = new Map<String, StageBar>();
        for (Opportunity o : d.openOpps) {
            StageBar bar = byStage.get(o.StageName);
            if (bar == null) {
                bar = new StageBar();
                bar.stage = o.StageName;
                bar.probability = o.Probability == null ? 0 : o.Probability;
                byStage.put(o.StageName, bar);
            }
            bar.count++;
            bar.amount += nvl(o.Amount);
        }
        List<StageBar> bars = byStage.values();
        bars.sort();
        Decimal maxAmount = 0;
        Integer maxCount = 0;
        for (StageBar b : bars) {
            maxAmount = Math.max(maxAmount, b.amount);
            maxCount = Math.max(maxCount, b.count);
        }
        for (StageBar b : bars) {
            b.amountLabel = formatAmount(b.amount);
            Decimal ratio = maxAmount > 0 ? b.amount / maxAmount : (maxCount > 0 ? (Decimal) b.count / maxCount : 0);
            b.percent = Math.max(6, (ratio * 100).intValue());
        }
        return bars;
    }

    private static List<ContactInfo> buildContacts(DataSet d) {
        List<ContactInfo> result = new List<ContactInfo>();
        for (Contact c : d.contacts) {
            if (result.size() >= 4) {
                break;
            }
            ContactInfo info = new ContactInfo();
            info.id = c.Id;
            info.name = c.Name;
            info.title = String.isBlank(c.Title) ? '役職未登録' : c.Title;
            info.initials = initials(c);
            Integer days = c.LastActivityDate == null ? null : c.LastActivityDate.daysBetween(d.today);
            info.lastTouchLabel = days == null ? '接点記録なし' : '最終接点 ' + relativeDays(days);
            info.isDormant = days == null || days >= DORMANT_CONTACT_DAYS;
            result.add(info);
        }
        return result;
    }

    private static List<TimelineEntry> buildTimeline(DataSet d) {
        List<TimelineEntry> entries = new List<TimelineEntry>();
        for (Task t : d.tasks) {
            if (t.IsClosed) {
                Date dt = t.ActivityDate != null ? t.ActivityDate : t.CreatedDate.date();
                entries.add(new TimelineEntry(t.Id, 'task', t.Subject, relatedLabel(t.What?.Name, t.Who?.Name),
                    Datetime.newInstance(dt, Time.newInstance(9, 0, 0, 0)), 'utility:task'));
            }
        }
        for (Event e : d.events) {
            if (e.StartDateTime != null && e.StartDateTime < d.now) {
                entries.add(new TimelineEntry(e.Id, 'event', e.Subject, relatedLabel(e.What?.Name, e.Who?.Name),
                    e.StartDateTime, 'utility:event'));
            }
        }
        for (Case c : d.cases) {
            entries.add(new TimelineEntry(c.Id, 'case', 'ケース起票: ' + c.Subject,
                '#' + c.CaseNumber + ' · 優先度 ' + c.Priority + ' · ' + c.Status, c.CreatedDate, 'utility:case'));
        }
        for (Opportunity o : d.opportunities) {
            if (o.IsWon && o.CloseDate != null && o.CloseDate <= d.today) {
                entries.add(new TimelineEntry(o.Id, 'won', '受注: ' + o.Name, formatAmount(o.Amount),
                    Datetime.newInstance(o.CloseDate, Time.newInstance(18, 0, 0, 0)), 'utility:success'));
            }
        }
        entries.sort();
        List<TimelineEntry> top = new List<TimelineEntry>();
        for (TimelineEntry e : entries) {
            if (top.size() >= 6) {
                break;
            }
            top.add(e);
        }
        return top;
    }

    // ------------------------------------------------------------------
    // Next actions
    // ------------------------------------------------------------------

    public class NextActionResult {
        @AuraEnabled public List<NextAction> actions;
        @AuraEnabled public Integer totalCandidates;
        @AuraEnabled public Integer highCount;
        @AuraEnabled public String headline;
        @AuraEnabled public Integer analyzedRecords;
        @AuraEnabled public String generatedAtLabel;

        public NextActionResult(List<NextAction> actions, Integer totalCandidates, Integer analyzedRecords, String generatedAtLabel) {
            this.actions = actions;
            this.totalCandidates = totalCandidates;
            this.analyzedRecords = analyzedRecords;
            this.generatedAtLabel = generatedAtLabel;
            this.highCount = 0;
            for (NextAction a : actions) {
                if (a.priority == 'high') {
                    this.highCount++;
                }
            }
            if (this.highCount > 0) {
                this.headline = '優先度「高」のアクションが ' + this.highCount + '件あります。上から順に着手すると効果的です。';
            } else {
                this.headline = '緊急の課題は見当たりません。関係強化と機会創出のアクションをおすすめします。';
            }
        }
    }

    public class NextAction implements Comparable {
        @AuraEnabled public String id;
        @AuraEnabled public String priority;
        @AuraEnabled public String priorityLabel;
        @AuraEnabled public String category;
        @AuraEnabled public String actionType;
        @AuraEnabled public String actionLabel;
        @AuraEnabled public String icon;
        @AuraEnabled public String title;
        @AuraEnabled public String reason;
        @AuraEnabled public String suggestion;
        @AuraEnabled public Integer confidence;
        @AuraEnabled public Integer impactScore;
        @AuraEnabled public String dueDate;
        @AuraEnabled public String dueLabel;
        @AuraEnabled public String dueRelative;
        @AuraEnabled public String relatedId;
        @AuraEnabled public String relatedName;
        @AuraEnabled public String relatedType;
        Integer priorityRank;

        public NextAction(String id, String priority, String category, String actionType) {
            this.id = id;
            this.priority = priority;
            this.category = category;
            this.actionType = actionType;
            this.priorityLabel = priority == 'high' ? '高' : (priority == 'medium' ? '中' : '低');
            this.priorityRank = priority == 'high' ? 0 : (priority == 'medium' ? 1 : 2);
            this.icon = ACTION_ICONS.get(actionType);
            this.actionLabel = ACTION_LABELS.get(actionType);
        }

        public void setDue(Date due, Date today) {
            this.dueDate = String.valueOf(due);
            this.dueLabel = AccountInsightsController.formatDate(due);
            Integer diff = today.daysBetween(due);
            this.dueRelative = diff <= 0 ? '今日中' : (diff == 1 ? '明日まで' : diff + '日以内');
        }

        public void setRelated(Id recordId, String name, String typeLabel) {
            this.relatedId = recordId;
            this.relatedName = name;
            this.relatedType = typeLabel;
        }

        public Integer compareTo(Object other) {
            NextAction o = (NextAction) other;
            if (priorityRank != o.priorityRank) {
                return priorityRank - o.priorityRank;
            }
            return (o.impactScore == null ? 0 : o.impactScore) - (impactScore == null ? 0 : impactScore);
        }
    }

    private static List<NextAction> buildActions(DataSet d) {
        List<NextAction> actions = new List<NextAction>();
        Set<Id> handledOpps = new Set<Id>();

        // 完了予定日を過ぎた商談
        for (Opportunity o : d.overdueOpps) {
            Integer late = o.CloseDate.daysBetween(d.today);
            NextAction a = new NextAction('opp-overdue-' + o.Id, 'high', '商談', 'meeting');
            a.title = '「' + o.Name + '」の決裁状況を確認し、完了予定日を再設定';
            a.reason = '完了予定日を ' + late + '日超過しています（フェーズ: ' + o.StageName + '）。放置するとフォーキャストの精度が下がります。';
            a.suggestion = '決裁者に検討状況と障壁をヒアリングし、現実的なクローズ日と次のマイルストーンを合意しましょう。';
            a.confidence = 88;
            a.impactScore = 84 + Math.min(late, 10);
            a.setDue(d.today.addDays(1), d.today);
            a.setRelated(o.Id, o.Name, '商談');
            actions.add(a);
            handledOpps.add(o.Id);
        }

        // クロージング間近の商談
        for (Opportunity o : d.closingSoonOpps) {
            Integer left = d.today.daysBetween(o.CloseDate);
            Integer prob = o.Probability == null ? 0 : o.Probability.intValue();
            NextAction a = new NextAction('opp-closing-' + o.Id, 'high', '商談', 'meeting');
            a.title = '「' + o.Name + '」のクロージングに向けた最終提案';
            a.reason = '完了予定日まで残り ' + left + '日・確度 ' + prob + '%・金額 ' + formatAmount(o.Amount) + '。今期の数字に直結する案件です。';
            a.suggestion = '見積条件の最終確認と契約手続きのスケジュールを提示し、懸念点を事前に解消しましょう。'
                + (String.isBlank(o.NextStep) ? '' : '（登録済みの次のステップ: ' + o.NextStep + '）');
            a.confidence = Math.min(95, 70 + prob / 4);
            a.impactScore = 86 + prob / 10;
            a.setDue(left <= 2 ? d.today : d.today.addDays(2), d.today);
            a.setRelated(o.Id, o.Name, '商談');
            actions.add(a);
            handledOpps.add(o.Id);
        }

        // 優先度「高」のケース
        for (Case c : d.highCases) {
            Integer age = c.CreatedDate.date().daysBetween(d.today);
            NextAction a = new NextAction('case-high-' + c.Id, 'high', 'サポート', 'call');
            a.title = 'ケース #' + c.CaseNumber + '「' + c.Subject + '」の対応状況を顧客へ共有';
            a.reason = '優先度「高」のケースが' + (age == 0 ? '本日' : ' ' + age + '日前に') + '起票され、ステータスは「' + c.Status
                + '」です。顧客満足度と進行中の商談への影響が懸念されます。';
            a.suggestion = 'サポート担当と解決見込みを確認したうえで、顧客の担当者へ電話で状況と今後の対応方針を伝えましょう。';
            a.confidence = 91;
            a.impactScore = 92;
            a.setDue(d.today, d.today);
            a.setRelated(c.Id, '#' + c.CaseNumber + ' ' + c.Subject, 'ケース');
            actions.add(a);
        }

        // 停滞中の商談
        for (Opportunity o : d.staleOpps) {
            if (handledOpps.contains(o.Id)) {
                continue;
            }
            NextAction a = new NextAction('opp-stale-' + o.Id, 'medium', '商談', 'email');
            a.title = '停滞中の「' + o.Name + '」へフォローアップ';
            a.reason = (o.LastActivityDate == null
                    ? '活動履歴が記録されていない商談です'
                    : o.LastActivityDate.daysBetween(d.today) + '日間活動がありません')
                + '（フェーズ: ' + o.StageName + '・' + formatAmount(o.Amount) + '）。失注リスクが高まっています。';
            a.suggestion = '導入事例や ROI 試算など新しい情報を添えて連絡し、次回打ち合わせの日程を確保しましょう。';
            a.confidence = 76;
            a.impactScore = 70 + Math.min(20, (nvl(o.Amount) / 1000000).intValue());
            a.setDue(d.today.addDays(3), d.today);
            a.setRelated(o.Id, o.Name, '商談');
            actions.add(a);
        }

        // その他の未解決ケース
        Integer otherCases = 0;
        for (Case c : d.openCases) {
            if (c.Priority == 'High' || otherCases >= 2) {
                continue;
            }
            Integer age = c.CreatedDate.date().daysBetween(d.today);
            Boolean isOld = age >= OLD_CASE_DAYS;
            NextAction a = new NextAction('case-open-' + c.Id, isOld ? 'medium' : 'low', 'サポート', 'task');
            a.title = 'ケース #' + c.CaseNumber + '「' + c.Subject + '」の進捗をフォロー';
            a.reason = (isOld ? '起票から ' + age + '日が経過しています' : '未解決のケースです')
                + '（優先度 ' + c.Priority + '・' + c.Status + '）。長期化すると満足度が低下します。';
            a.suggestion = 'サポートチームと解決予定日をすり合わせ、顧客へ進捗をひとこと共有しておきましょう。';
            a.confidence = isOld ? 74 : 62;
            a.impactScore = isOld ? 60 : 45;
            a.setDue(d.today.addDays(isOld ? 2 : 5), d.today);
            a.setRelated(c.Id, '#' + c.CaseNumber + ' ' + c.Subject, 'ケース');
            actions.add(a);
            otherCases++;
        }

        // 期限切れの ToDo
        if (!d.overdueTasks.isEmpty()) {
            Task t = d.overdueTasks[0];
            NextAction a = new NextAction('task-overdue', 'medium', '活動', 'task');
            a.title = '期限切れの ToDo ' + d.overdueTasks.size() + '件を消化・整理';
            a.reason = '「' + t.Subject + '」など、期限を過ぎた ToDo が残っています。顧客との約束事項が漏れている可能性があります。';
            a.suggestion = '不要な ToDo はクローズし、必要なものは期限を再設定して本日中に着手しましょう。';
            a.confidence = 80;
            a.impactScore = 58 + d.overdueTasks.size() * 2;
            a.setDue(d.today, d.today);
            a.setRelated(t.Id, t.Subject, 'ToDo');
            actions.add(a);
        }

        // 直近の予定の事前準備
        if (d.nextEvent != null && d.today.daysBetween(d.nextEvent.StartDateTime.date()) <= 7) {
            Date eventDate = d.nextEvent.StartDateTime.date();
            Integer daysLeft = d.today.daysBetween(eventDate);
            NextAction a = new NextAction('event-prep', 'medium', '活動', 'task');
            a.title = '「' + d.nextEvent.Subject + '」の事前準備';
            a.reason = formatDate(eventDate) + ' の予定まで' + (daysLeft == 0 ? '本日' : 'あと ' + daysLeft + '日') + 'です。'
                + '進行中の商談 ' + d.openOpps.size() + '件・未解決ケース ' + d.openCases.size() + '件を踏まえた準備が必要です。';
            a.suggestion = 'AI サマリーの論点（パイプライン・サポート状況）をアジェンダに反映し、参加者へ事前共有しましょう。';
            a.confidence = 72;
            a.impactScore = 66;
            a.setDue(daysLeft <= 1 ? d.today : eventDate.addDays(-1), d.today);
            a.setRelated(d.nextEvent.Id, d.nextEvent.Subject, '行動');
            actions.add(a);
        }

        // 受注後のアップセル
        if (!d.wonOpps.isEmpty()) {
            Opportunity won = d.wonOpps[0];
            Integer since = won.CloseDate.daysBetween(d.today);
            if (since >= 14 && since <= 180) {
                NextAction a = new NextAction('upsell-' + won.Id, 'medium', '拡大', 'meeting');
                a.title = '「' + won.Name + '」の導入効果レビューとアップセル提案';
                a.reason = '受注から ' + since + '日が経過しました。導入後の満足度確認は追加提案の絶好のタイミングです。';
                a.suggestion = '活用状況と成果を一緒に振り返る場を設け、他部門への展開や上位プランの提案につなげましょう。';
                a.confidence = 68;
                a.impactScore = 64;
                a.setDue(d.today.addDays(7), d.today);
                a.setRelated(won.Id, won.Name, '商談');
                actions.add(a);
            }
        }

        // 新規商談の創出
        if (d.openOpps.isEmpty()) {
            NextAction a = new NextAction('new-opportunity', 'medium', '拡大', 'meeting');
            a.title = '新たな商談機会の創出に向けたヒアリングを設定';
            a.reason = '進行中の商談がありません。' + (d.wonOpps.isEmpty()
                ? '課題のヒアリングから関係を深める段階です。'
                : '既存取引の実績を足がかりに次の提案を検討できます。');
            a.suggestion = '業界動向や同業他社の事例を切り口に、今期の重点課題をヒアリングする打ち合わせを打診しましょう。';
            a.confidence = 70;
            a.impactScore = 62;
            a.setDue(d.today.addDays(7), d.today);
            a.setRelated(d.account.Id, d.account.Name, '取引先');
            actions.add(a);
        }

        // 接点の減少
        if (d.recentActivityCount == 0) {
            Integer idle = d.daysSinceLastActivity();
            NextAction a = new NextAction('engagement', 'medium', 'リレーション', 'call');
            a.title = '定期的な接点（月次定例など）を設定';
            a.reason = idle == null
                ? '活動履歴が記録されていません。接点がない状態が続くと関係が希薄になります。'
                : '最後の接点から ' + idle + '日が経過しています。直近30日間の活動がありません。';
            a.suggestion = '主要な取引先責任者に電話で近況を伺い、月次の定例ミーティングを提案しましょう。';
            a.confidence = 78;
            a.impactScore = 60;
            a.setDue(d.today.addDays(2), d.today);
            a.setRelated(d.account.Id, d.account.Name, '取引先');
            actions.add(a);
        }

        // 接点が途切れているキーパーソン
        Integer dormantAdded = 0;
        for (Contact c : d.contacts) {
            if (dormantAdded >= 2) {
                break;
            }
            Integer days = c.LastActivityDate == null ? null : c.LastActivityDate.daysBetween(d.today);
            if (days != null && days < DORMANT_CONTACT_DAYS) {
                continue;
            }
            NextAction a = new NextAction('contact-' + c.Id, 'low', 'リレーション', 'email');
            a.title = c.Name + ' 様' + (String.isBlank(c.Title) ? '' : '（' + c.Title + '）') + 'との関係を再構築';
            a.reason = (days == null ? '活動記録がありません。' : days + '日間接点がありません。')
                + 'キーパーソンとの接点減少は失注・解約の先行指標です。';
            a.suggestion = '業界トレンドや導入事例など価値のある情報を添えて近況伺いのメールを送り、面談の機会をつくりましょう。';
            a.confidence = 64;
            a.impactScore = 40;
            a.setDue(d.today.addDays(7), d.today);
            a.setRelated(c.Id, c.Name, '取引先責任者');
            actions.add(a);
            dormantAdded++;
        }

        if (actions.isEmpty()) {
            NextAction a = new NextAction('keep-in-touch', 'low', 'リレーション', 'email');
            a.title = '近況伺いの連絡で良好な関係を維持';
            a.reason = '大きなリスクは検出されていません。定期的な情報提供で関係を維持しましょう。';
            a.suggestion = '最新の製品アップデートや事例を共有し、次の検討テーマを探りましょう。';
            a.confidence = 60;
            a.impactScore = 30;
            a.setDue(d.today.addDays(14), d.today);
            a.setRelated(d.account.Id, d.account.Name, '取引先');
            actions.add(a);
        }
        return actions;
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    @TestVisible
    private static String formatAmount(Decimal amount) {
        Decimal a = nvl(amount);
        String iso = UserInfo.getDefaultCurrency();
        if (iso == 'JPY') {
            if (a >= 100000000) {
                return (a / 100000000).setScale(1).format() + '億円';
            }
            if (a >= 10000) {
                return (a / 10000).setScale(0).format() + '万円';
            }
            return a.setScale(0).format() + '円';
        }
        if (a >= 1000000) {
            return iso + ' ' + (a / 1000000).setScale(1).format() + 'M';
        }
        if (a >= 1000) {
            return iso + ' ' + (a / 1000).setScale(1).format() + 'K';
        }
        return iso + ' ' + a.setScale(0).format();
    }

    @TestVisible
    private static String formatDate(Date d) {
        if (d == null) {
            return '';
        }
        Integer weekday = Math.mod(Date.newInstance(1900, 1, 7).daysBetween(d), 7);
        return d.month() + '/' + d.day() + '(' + WEEKDAYS[weekday] + ')';
    }

    private static String relativeDays(Integer days) {
        if (days == null) {
            return '-';
        }
        if (days <= 0) {
            return '今日';
        }
        return days == 1 ? '昨日' : days + '日前';
    }

    private static String relatedLabel(String whatName, String whoName) {
        List<String> parts = new List<String>();
        addIfNotBlank(parts, whatName);
        addIfNotBlank(parts, whoName);
        return String.join(parts, ' · ');
    }

    private static String initials(Contact c) {
        String last = String.isBlank(c.LastName) ? '' : c.LastName;
        String first = String.isBlank(c.FirstName) ? '' : c.FirstName;
        if (Pattern.matches('^[A-Za-z].*', last)) {
            return (first.left(1) + last.left(1)).toUpperCase();
        }
        return last.left(1);
    }

    private static void addIfNotBlank(List<String> target, String value) {
        if (String.isNotBlank(value)) {
            target.add(value);
        }
    }

    private static Decimal nvl(Decimal value) {
        return value == null ? 0 : value;
    }

    private static AuraHandledException newAuraException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
