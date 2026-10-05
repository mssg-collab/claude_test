import { createElement } from 'lwc';
import AccountNextActions from 'c/accountNextActions';
import getNextActions from '@salesforce/apex/AccountInsightsController.getNextActions';
import createFollowUpTask from '@salesforce/apex/AccountInsightsController.createFollowUpTask';

jest.mock(
    '@salesforce/apex/AccountInsightsController.getNextActions',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AccountInsightsController.createFollowUpTask',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

function action(id, priority, extra = {}) {
    return {
        id,
        priority,
        priorityLabel: { high: '高', medium: '中', low: '低' }[priority],
        category: '商談',
        actionType: 'meeting',
        actionLabel: '打ち合わせ',
        icon: 'utility:event',
        title: `${id} のタイトル`,
        reason: '根拠テキスト',
        suggestion: '推奨アプローチ',
        confidence: 80,
        impactScore: 90,
        dueDate: '2026-10-07',
        dueLabel: '10/7(水)',
        dueRelative: '2日以内',
        relatedId: '006000000000001',
        relatedName: '全社 CRM 刷新',
        relatedType: '商談',
        ...extra
    };
}

const RESULT = {
    actions: [action('a1', 'high'), action('a2', 'high'), action('a3', 'medium'), action('a4', 'low')],
    totalCandidates: 7,
    highCount: 2,
    headline: '優先度「高」のアクションが 2件あります。',
    analyzedRecords: 23,
    generatedAtLabel: '2026/10/05 15:00'
};

async function settle() {
    for (let i = 0; i < 4; i++) {
        jest.advanceTimersByTime(1000);
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

async function render() {
    const element = createElement('c-account-next-actions', { is: AccountNextActions });
    element.recordId = '001000000000001';
    document.body.appendChild(element);
    await settle();
    return element;
}

describe('c-account-next-actions', () => {
    beforeEach(() => {
        jest.useFakeTimers();
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        jest.useRealTimers();
    });

    it('renders prioritized actions with the top pick highlighted', async () => {
        getNextActions.mockResolvedValue(RESULT);
        const element = await render();
        const root = element.shadowRoot;

        expect(getNextActions).toHaveBeenCalledWith({ accountId: '001000000000001', maxActions: 6 });
        const items = root.querySelectorAll('.item');
        expect(items.length).toBe(4);
        expect(items[0].classList.contains('item_top')).toBe(true);
        expect(root.querySelector('.chip_top')).not.toBeNull();
        expect(root.querySelectorAll('.suggest').length).toBe(1);
        expect(root.querySelector('.progress__label').textContent).toBe('0 / 4 件 対応済み');
    });

    it('filters by priority', async () => {
        getNextActions.mockResolvedValue(RESULT);
        const element = await render();
        const root = element.shadowRoot;

        root.querySelector('button.filter[data-value="high"]').click();
        await Promise.resolve();

        expect(root.querySelectorAll('.item').length).toBe(2);
        expect(root.querySelector('button.filter[data-value="high"]').getAttribute('aria-pressed')).toBe('true');
    });

    it('marks an action as done and moves the top pick to the next one', async () => {
        getNextActions.mockResolvedValue(RESULT);
        const element = await render();
        const root = element.shadowRoot;

        const doneButton = Array.from(root.querySelectorAll('lightning-button')).find((b) => b.label === '対応済み');
        doneButton.click();
        await Promise.resolve();

        const items = root.querySelectorAll('.item');
        expect(items[0].classList.contains('item_handled')).toBe(true);
        expect(items[1].classList.contains('item_top')).toBe(true);
        expect(root.querySelector('.progress__label').textContent).toBe('1 / 4 件 対応済み');
    });

    it('creates a follow-up task through Apex', async () => {
        getNextActions.mockResolvedValue(RESULT);
        createFollowUpTask.mockResolvedValue('00T000000000001');
        const element = await render();
        const root = element.shadowRoot;
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        const createButton = Array.from(root.querySelectorAll('lightning-button')).find(
            (b) => b.label === 'ToDo を作成'
        );
        createButton.click();
        await Promise.resolve();
        await Promise.resolve();
        await Promise.resolve();

        expect(createFollowUpTask).toHaveBeenCalledWith(
            expect.objectContaining({
                accountId: '001000000000001',
                relatedId: '006000000000001',
                subject: 'a1 のタイトル',
                dueDate: '2026-10-07',
                priority: 'high'
            })
        );
        expect(toastHandler).toHaveBeenCalled();
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(root.querySelector('.handled').textContent).toContain('ToDo を登録しました');
    });

    it('shows an error message when Apex fails', async () => {
        getNextActions.mockRejectedValue({ body: { message: '取引先が見つかりません' } });
        const element = await render();

        expect(element.shadowRoot.querySelector('.error__message').textContent).toBe('取引先が見つかりません');
    });
});
