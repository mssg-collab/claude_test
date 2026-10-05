import { LightningElement, api } from 'lwc';
import getAccountSummary from '@salesforce/apex/AccountInsightsController.getAccountSummary';

const ANALYSIS_STEPS = [
    '取引先プロファイルを読み込んでいます',
    '商談パイプラインを分析しています',
    'サポートケースを評価しています',
    '活動履歴からエンゲージメントを算出しています',
    'インサイトを生成しています'
];
const MIN_LOADING_MS = 1800;
const STEP_INTERVAL_MS = 380;
const TYPING_INTERVAL_MS = 16;
const TYPING_CHARS_PER_TICK = 2;
const RING_RADIUS = 52;
const AVATAR_COLORS = ['#7f3fe0', '#0b5cab', '#06a59a', '#e3066a', '#dd7a01', '#3a49da'];

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

export default class AccountAiSummary extends LightningElement {
    @api recordId;
    @api disableTypingEffect = false;

    data;
    error;
    isLoading = true;
    stepIndex = 0;
    displayedNarrative = '';
    isTyping = false;
    displayScore = 0;
    ringReady = false;
    copied = false;

    stepTimer;
    typingTimer;
    scoreTimer;

    connectedCallback() {
        this.generate();
    }

    disconnectedCallback() {
        this.clearTimers();
    }

    async generate() {
        this.clearTimers();
        this.isLoading = true;
        this.error = undefined;
        this.stepIndex = 0;
        this.ringReady = false;
        this.displayScore = 0;
        this.displayedNarrative = '';

        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.stepTimer = setInterval(() => {
            if (this.stepIndex < ANALYSIS_STEPS.length - 1) {
                this.stepIndex += 1;
            }
        }, STEP_INTERVAL_MS);

        try {
            const [result] = await Promise.all([
                getAccountSummary({ accountId: this.recordId }),
                delay(MIN_LOADING_MS)
            ]);
            this.data = result;
            this.isLoading = false;
            this.startReveal();
        } catch (e) {
            this.data = undefined;
            this.error = reduceError(e);
            this.isLoading = false;
        } finally {
            clearInterval(this.stepTimer);
        }
    }

    startReveal() {
        const target = this.data.healthScore || 0;
        const narrative = this.data.narrative || '';

        // ヘルススコアのカウントアップとリングのアニメーション
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            this.ringReady = true;
        });
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.scoreTimer = setInterval(() => {
            this.displayScore = Math.min(target, this.displayScore + Math.max(1, Math.ceil(target / 40)));
            if (this.displayScore >= target) {
                clearInterval(this.scoreTimer);
            }
        }, 20);

        // 生成 AI 風のタイピング表示
        if (this.disableTypingEffect) {
            this.displayedNarrative = narrative;
            return;
        }
        this.isTyping = true;
        let index = 0;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.typingTimer = setInterval(() => {
            index += TYPING_CHARS_PER_TICK;
            this.displayedNarrative = narrative.slice(0, index);
            if (index >= narrative.length) {
                this.finishTyping();
            }
        }, TYPING_INTERVAL_MS);
    }

    finishTyping() {
        clearInterval(this.typingTimer);
        this.isTyping = false;
        if (this.data) {
            this.displayedNarrative = this.data.narrative;
        }
    }

    clearTimers() {
        clearInterval(this.stepTimer);
        clearInterval(this.typingTimer);
        clearInterval(this.scoreTimer);
    }

    handleRegenerate() {
        this.generate();
    }

    handleSkipTyping() {
        if (this.isTyping) {
            this.finishTyping();
        }
    }

    handleCopy() {
        const text = `${this.data.headline}\n${this.data.narrative}`;
        if (navigator.clipboard) {
            navigator.clipboard.writeText(text);
            this.copied = true;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                this.copied = false;
            }, 1800);
        }
    }

    // ---------- view getters ----------

    get hasData() {
        return !this.isLoading && !this.error && !!this.data;
    }

    get subtitle() {
        if (this.isLoading) {
            return '分析中…';
        }
        if (this.data) {
            return `${this.data.analyzedRecords} 件のレコードを分析 · ${this.data.generatedAtLabel} 生成`;
        }
        return '';
    }

    get loadingSteps() {
        return ANALYSIS_STEPS.map((label, i) => {
            let state = 'pending';
            if (i < this.stepIndex) {
                state = 'done';
            } else if (i === this.stepIndex) {
                state = 'active';
            }
            return { key: `step-${i}`, label, cls: `step step_${state}`, isDone: state === 'done' };
        });
    }

    get copyLabel() {
        return this.copied ? 'コピーしました' : '要約をコピー';
    }

    get narrativeClass() {
        return this.isTyping ? 'narrative__text narrative__text_typing' : 'narrative__text';
    }

    get heroClass() {
        return `hero hero_${this.data.healthTone}`;
    }

    get ringCircumference() {
        return (2 * Math.PI * RING_RADIUS).toFixed(2);
    }

    get ringOffset() {
        const score = this.ringReady ? this.data.healthScore : 0;
        return ((2 * Math.PI * RING_RADIUS * (100 - score)) / 100).toFixed(2);
    }

    get tagItems() {
        return (this.data.tags || []).map((tag, i) => ({ key: `tag-${i}`, label: tag }));
    }

    get kpiItems() {
        return (this.data.kpis || []).map((k, i) => ({
            ...k,
            cls: `kpi kpi_${k.tone}`,
            style: `animation-delay:${i * 90}ms`
        }));
    }

    get insightItems() {
        return (this.data.insights || []).map((item, i) => ({
            ...item,
            cls: `insight insight_${item.kind}`,
            style: `animation-delay:${200 + i * 90}ms`
        }));
    }

    get hasStageBars() {
        return this.data.stageBars && this.data.stageBars.length > 0;
    }

    get stageItems() {
        return this.data.stageBars.map((b, i) => ({
            ...b,
            key: `stage-${i}`,
            barStyle: `width:${b.percent}%;animation-delay:${300 + i * 120}ms`
        }));
    }

    get hasContacts() {
        return this.data.keyContacts && this.data.keyContacts.length > 0;
    }

    get contactItems() {
        return this.data.keyContacts.map((c, i) => ({
            ...c,
            avatarStyle: `background:${AVATAR_COLORS[i % AVATAR_COLORS.length]}`,
            touchCls: c.isDormant ? 'contact__touch contact__touch_dormant' : 'contact__touch'
        }));
    }

    get hasTimeline() {
        return this.data.timeline && this.data.timeline.length > 0;
    }

    get timelineItems() {
        return this.data.timeline.map((t) => ({
            ...t,
            dotCls: `timeline__dot timeline__dot_${t.kind}`
        }));
    }
}
