import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["account", "percentage", "total", "submit"];

  connect() {
    this.update();
  }

  update() {
    const checkedIds = new Set(
      this.accountTargets
        .filter((checkbox) => checkbox.checked)
        .map((checkbox) => checkbox.dataset.accountId),
    );
    const selectedIds = checkedIds.size
      ? checkedIds
      : new Set(this.percentageTargets.map((input) => input.dataset.accountId));

    let total = 0;
    for (const input of this.percentageTargets) {
      const selected = selectedIds.has(input.dataset.accountId);
      input.disabled = !selected;
      if (selected) total += Number.parseFloat(input.value) || 0;
    }

    const roundedTotal = Math.round(total * 100) / 100;
    const valid =
      this.percentageTargets.length === 0 ||
      Math.abs(roundedTotal - 100) < 0.001;
    this.totalTarget.textContent = `${roundedTotal.toLocaleString()} %`;
    this.totalTarget.classList.toggle("text-success", valid);
    this.totalTarget.classList.toggle("text-destructive", !valid);
    this.submitTarget.disabled = !valid;
  }
}
