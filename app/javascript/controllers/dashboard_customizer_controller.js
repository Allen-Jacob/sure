import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["section", "toggle", "empty"];

  toggle(event) {
    const toggle = event.currentTarget;
    this.setVisibility(toggle.dataset.sectionKey, toggle.checked);
  }

  hide(event) {
    event.preventDefault();
    event.stopPropagation();

    const sectionKey = event.currentTarget.dataset.sectionKey;
    const toggle = this.toggleTargets.find(
      (candidate) => candidate.dataset.sectionKey === sectionKey,
    );

    if (toggle) toggle.checked = false;
    this.setVisibility(sectionKey, false);
  }

  async setVisibility(sectionKey, visible) {
    const section = this.sectionTargets.find(
      (candidate) => candidate.dataset.sectionKey === sectionKey,
    );
    if (!section) return;

    const previousVisibility = !section.hidden;
    section.hidden = !visible;
    this.updateEmptyState();
    window.dispatchEvent(new Event("resize"));

    const saved = await this.savePreference(sectionKey, !visible);
    if (!saved) {
      section.hidden = !previousVisibility;
      const toggle = this.toggleTargets.find(
        (candidate) => candidate.dataset.sectionKey === sectionKey,
      );
      if (toggle) toggle.checked = previousVisibility;
      this.updateEmptyState();
      window.dispatchEvent(new Event("resize"));
    }
  }

  updateEmptyState() {
    if (!this.hasEmptyTarget) return;

    this.emptyTarget.classList.toggle(
      "hidden",
      this.sectionTargets.some((section) => !section.hidden),
    );
  }

  async savePreference(sectionKey, hidden) {
    const csrfToken = document.querySelector('meta[name="csrf-token"]');
    if (!csrfToken) {
      console.error(
        "[Dashboard Customizer] CSRF token not found. Cannot save preferences.",
      );
      return false;
    }

    try {
      const response = await fetch("/dashboard/preferences", {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken.content,
        },
        body: JSON.stringify({
          preferences: { hidden_sections: { [sectionKey]: hidden } },
        }),
      });

      if (!response.ok) {
        console.error(
          "[Dashboard Customizer] Failed to save preferences:",
          response.status,
        );
        return false;
      }

      return true;
    } catch (error) {
      console.error(
        "[Dashboard Customizer] Network error saving preferences:",
        error,
      );
      return false;
    }
  }
}
