import { createElement } from 'lwc';
import AccountAiSummary from 'c/accountAiSummary';
import getAccountSummary from '@salesforce/apex/AccountInsightsController.getAccountSummary';

jest.mock(
    '@salesforce/apex/AccountInsightsController.getAccountSummary',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const SUMMARY = {
    accountName: '株式会社ミライテック（デモ）',
    profileLine: 'Technology · Customer - Direct · 東京都港区',
    healthScore: 72,
    healthLabel: '安定',
    healthTone: 'stable',
    headline: '安定した関係です。',
    narrative: '株式会社ミライテック（デモ）はTechnology業界の取引先です。',
    tags: ['#ホット取引先', '#クロージング間近'],
    kpis: [
        { key: 'pipeline', label: '進行中の商談', value: '8,850万円', subText: '3件', icon: 'utility:opportunity', tone: 'positive' },
        { key: 'cases', label: '未解決ケース', value: '2件', subText: '高 1件', icon: 'utility:case', tone: 'negative' }
    ],
    insights: [{ key: 'case', kind: 'risk', title: '優先度「高」のケースが 1件', detail: '詳細', icon: 'utility:warning' }],
    stageBars: [{ stage: 'Negotiation/Review', count: 1, amountLabel: '4,800万円', percent: 100 }],
    keyContacts: [{ id: '003000000000001', name: '高橋 誠', title: 'CIO', initials: '高', lastTouchLabel: '最終接点 2日前', isDormant: false }],
    timeline: [{ id: '00T000000000001', kind: 'task', title: '最終見積の提示', subtitle: '全社 CRM', dateLabel: '10/3(土)', icon: 'utility:task' }],
    analyzedRecords: 23,
    generatedAtLabel: '2026/10/05 15:00'
};

async function settle() {
    for (let i = 0; i < 5; i++) {
        jest.advanceTimersByTime(1000);
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

describe('c-account-ai-summary', () => {
    beforeEach(() => {
        jest.useFakeTimers();
        global.requestAnimationFrame = (cb) => cb();
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        jest.useRealTimers();
    });

    it('shows the analysis steps first, then renders the summary', async () => {
        getAccountSummary.mockResolvedValue(SUMMARY);
        const element = createElement('c-account-ai-summary', { is: AccountAiSummary });
        element.recordId = '001000000000001';
        document.body.appendChild(element);

        expect(element.shadowRoot.querySelectorAll('.step').length).toBe(5);
        expect(getAccountSummary).toHaveBeenCalledWith({ accountId: '001000000000001' });

        await settle();

        const root = element.shadowRoot;
        expect(root.querySelector('.hero__name').textContent).toBe(SUMMARY.accountName);
        expect(root.querySelector('.health__score').textContent).toBe('72');
        expect(root.querySelector('.narrative__text').textContent).toBe(SUMMARY.narrative);
        expect(root.querySelectorAll('.kpi').length).toBe(2);
        expect(root.querySelector('.kpi_negative')).not.toBeNull();
        expect(root.querySelectorAll('.tag').length).toBe(2);
        expect(root.querySelector('.insight_risk')).not.toBeNull();
        expect(root.querySelector('.stage__fill').getAttribute('style')).toContain('width:100%');
        expect(root.querySelector('.contact__name').textContent).toBe('高橋 誠');
        expect(root.querySelector('.timeline__title').textContent).toBe('最終見積の提示');
    });

    it('shows a friendly error message when Apex fails', async () => {
        getAccountSummary.mockRejectedValue({ body: { message: '権限がありません' } });
        const element = createElement('c-account-ai-summary', { is: AccountAiSummary });
        element.recordId = '001000000000001';
        document.body.appendChild(element);

        await settle();

        expect(element.shadowRoot.querySelector('.error__message').textContent).toBe('権限がありません');
    });
});
