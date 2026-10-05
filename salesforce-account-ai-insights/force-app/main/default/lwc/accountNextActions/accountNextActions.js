import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
import getNextActions from '@salesforce/apex/AccountInsightsController.getNextActions';
import createFollowUpTask from '@salesforce/apex/AccountInsightsController.createFollowUpTask';

const MIN_LOADING_MS = 1400;
const FILTERS = [
    { value: 'all', label: 'すべて' },
    { value: 'high', label: '優先度 高' },
    { value: 'medium', label: '中' },
    { value: 'low', label: '低' }
];
const STATUS_LABELS = {
    task: 'ToDo を登録しました',
    done: '対応済みにしました',
    dismissed: '今回は見送りました'
};

function delay(ms) {
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    return new Promise((resolve) => setTimeout(resolve, ms));
}

function reduceError(error) {
    if (!error) {
        return '不明なエラーが発生しました。';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return error.body?.message || error.message || '不明なエラーが発生しました。';
}

export default class AccountNextActions extends NavigationMixin(LightningElement) {
    @api recordId;
    @api maxActions = 6;

    result;
    items = [];
    error;
    isLoading = true;
    filter = 'all';

    connectedCallback() {
        this.load();
    }

    async load() {
        this.isLoading = true;
        this.error = undefined;
        try {
            const [result] = await Promise.all([
                getNextActions({ accountId: this.recordId, maxActions: Number(this.maxActions) || 6 }),
                delay(MIN_LOADING_MS)
            ]);
            this.result = result;
            this.items = (result.actions || []).map((a, index) => ({
                ...a,
                status: 'open',
                expanded: index === 0,
                saving: false
            }));
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.isLoading = false;
        }
    }

    // ---------- handlers ----------

    handleRefresh() {
        this.filter = 'all';
        this.load();
    }

    handleFilter(event) {
        this.filter = event.currentTarget.dataset.value;
    }

    handleToggle(event) {
        const item = this.findItem(event);
        if (item) {
            this.updateItem(item.id, { expanded: !item.expanded });
        }
    }

    handleDone(event) {
        const item = this.findItem(event);
        if (item) {
            this.updateItem(item.id, { status: 'done', expanded: false });
        }
    }

    handleDismiss(event) {
        const item = this.findItem(event);
        if (item) {
            this.updateItem(item.id, { status: 'dismissed', expanded: false });
        }
    }

    handleUndo(event) {
        const item = this.findItem(event);
        if (item) {
            this.updateItem(item.id, { status: 'open' });
        }
    }

    handleNavigate(event) {
        const recordId = event.currentTarget.dataset.recordId;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId, actionName: 'view' }
        });
    }

    async handleCreateTask(event) {
        const item = this.findItem(event);
        if (!item || item.saving) {
            return;
        }
        this.updateItem(item.id, { saving: true });
        try {
            await createFollowUpTask({
                accountId: this.recordId,
                relatedId: item.relatedId,
                subject: item.title,
                description: `【AI ネクストアクション】\n根拠: ${item.reason}\n推奨アプローチ: ${item.suggestion}`,
                dueDate: item.dueDate,
                priority: item.priority
            });
            this.updateItem(item.id, { saving: false, status: 'task', expanded: false });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'ToDo を作成しました',
                    message: `「${item.title}」（期日 ${item.dueLabel}）`,
                    variant: 'success'
                })
            );
            this.dispatchEvent(new RefreshEvent());
        } catch (e) {
            this.updateItem(item.id, { saving: false });
            this.dispatchEvent(
                new ShowToastEvent({ title: 'ToDo を作成できませんでした', message: reduceError(e), variant: 'error' })
            );
        }
    }

    findItem(event) {
        const id = event.currentTarget.dataset.id;
        return this.items.find((i) => i.id === id);
    }

    updateItem(id, patch) {
        this.items = this.items.map((i) => (i.id === id ? { ...i, ...patch } : i));
    }

    // ---------- view getters ----------

    get hasResult() {
        return !this.isLoading && !this.error && !!this.result;
    }

    get subtitle() {
        if (this.isLoading) {
            return '次の一手を検討中…';
        }
        if (this.result) {
            return `${this.result.analyzedRecords} 件のレコードから ${this.result.totalCandidates} 件の候補を評価 · ${this.result.generatedAtLabel}`;
        }
        return '';
    }

    get totalCount() {
        return this.items.length;
    }

    get handledCount() {
        return this.items.filter((i) => i.status !== 'open').length;
    }

    get progressStyle() {
        const pct = this.totalCount ? Math.round((this.handledCount / this.totalCount) * 100) : 0;
        return `width:${pct}%`;
    }

    get isAllHandled() {
        return this.totalCount > 0 && this.handledCount === this.totalCount;
    }

    get filterOptions() {
        return FILTERS.map((f) => {
            const count =
                f.value === 'all' ? this.items.length : this.items.filter((i) => i.priority === f.value).length;
            const active = this.filter === f.value;
            return {
                ...f,
                count,
                pressed: active ? 'true' : 'false',
                cls: active ? 'filter filter_active' : 'filter'
            };
        });
    }

    get topPickId() {
        const first = this.items.find((i) => i.status === 'open');
        return first ? first.id : null;
    }

    get visibleActions() {
        const topPickId = this.topPickId;
        return this.items
            .filter((i) => this.filter === 'all' || i.priority === this.filter)
            .map((i, index) => {
                const isOpen = i.status === 'open';
                const isTopPick = i.id === topPickId;
                const classes = ['item', `item_${i.priority}`];
                if (isTopPick) {
                    classes.push('item_top');
                }
                if (!isOpen) {
                    classes.push('item_handled');
                }
                return {
                    ...i,
                    isOpen,
                    isTopPick,
                    cls: classes.join(' '),
                    style: `animation-delay:${index * 90}ms`,
                    iconCls: `item__icon item__icon_${i.actionType}`,
                    priorityCls: `chip chip_${i.priority}`,
                    confidenceStyle: `width:${i.confidence}%`,
                    toggleLabel: i.expanded ? '提案を閉じる' : 'AI の提案を見る',
                    toggleIcon: i.expanded ? 'utility:chevronup' : 'utility:chevrondown',
                    createLabel: i.saving ? '作成中…' : 'ToDo を作成',
                    statusLabel: STATUS_LABELS[i.status],
                    statusIcon: i.status === 'dismissed' ? 'utility:hide' : 'utility:success'
                };
            });
    }

    get hasVisibleActions() {
        return this.visibleActions.length > 0;
    }
}
