export class RefreshEvent extends CustomEvent {
    constructor() {
        super('lightning__refreshevent', { bubbles: true, composed: true });
    }
}
