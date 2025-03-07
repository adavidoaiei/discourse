import { action } from "@ember/object";
import { cancel, next } from "@ember/runloop";
import { tracked } from "@glimmer/tracking";
import discourseLater from "discourse-common/lib/later";
import { makeArray } from "discourse-common/lib/helpers";
import { bind } from "discourse-common/utils/decorators";

const TOUCH_OPTIONS = { passive: true, capture: true };

function cancelEvent(event) {
  event.preventDefault();
  event.stopImmediatePropagation();
}

export default class FloatKitInstance {
  @tracked expanded = false;
  @tracked id = null;

  trigger = null;
  content = null;

  @action
  async show() {
    this.expanded = true;

    await new Promise((resolve) => next(resolve));
  }

  @action
  async close() {
    this.expanded = false;

    await new Promise((resolve) => next(resolve));
  }

  @action
  onFocus(event) {
    this.onTrigger(event);
  }

  @action
  onBlur(event) {
    this.onTrigger(event);
  }

  @action
  onFocusIn(event) {
    this.onTrigger(event);
  }

  @action
  onFocusOut(event) {
    this.onTrigger(event);
  }

  @action
  onTouchStart(event) {
    if (event.touches.length > 1) {
      this.onTouchCancel();
      return;
    }

    event.stopPropagation();

    this.trigger.addEventListener(
      "touchmove",
      this.onTouchCancel,
      TOUCH_OPTIONS
    );
    this.trigger.addEventListener(
      "touchcancel",
      this.onTouchCancel,
      TOUCH_OPTIONS
    );
    this.trigger.addEventListener(
      "touchend",
      this.onTouchCancel,
      TOUCH_OPTIONS
    );
    this.touchTimeout = discourseLater(() => {
      if (this.isDestroying || this.isDestroyed) {
        return;
      }

      this.trigger.addEventListener("touchend", cancelEvent, {
        once: true,
        capture: true,
      });

      this.onTrigger(event);
    }, 500);
  }

  @bind
  onTouchCancel() {
    cancel(this.touchTimeout);

    this.trigger.removeEventListener("touchmove", this.onTouchCancel);
    this.trigger.removeEventListener("touchend", this.onTouchCancel);
    this.trigger.removeEventListener("touchcancel", this.onTouchCancel);
  }

  tearDownListeners() {
    if (!this.options.listeners) {
      return;
    }

    makeArray(this.triggers)
      .filter(Boolean)
      .forEach((trigger) => {
        switch (trigger) {
          case "hold":
            this.trigger.addEventListener("touchstart", this.onTouchStart);
            break;
          case "focus":
            this.trigger.removeEventListener("focus", this.onFocus);
            this.trigger.removeEventListener("blur", this.onBlur);
            break;
          case "focusin":
            this.trigger.removeEventListener("focusin", this.onFocusIn);
            this.trigger.removeEventListener("focusout", this.onFocusOut);
            break;
          case "hover":
            this.trigger.removeEventListener("mousemove", this.onMouseMove);
            if (!this.options.interactive) {
              this.trigger.removeEventListener("mouseleave", this.onMouseLeave);
            }

            break;
          case "click":
            this.trigger.removeEventListener("click", this.onClick);
            break;
        }
      });

    cancel(this.touchTimeout);
  }

  setupListeners() {
    if (!this.options.listeners) {
      return;
    }

    makeArray(this.triggers)
      .filter(Boolean)
      .forEach((trigger) => {
        switch (trigger) {
          case "hold":
            this.trigger.addEventListener(
              "touchstart",
              this.onTouchStart,
              TOUCH_OPTIONS
            );
            break;
          case "focus":
            this.trigger.addEventListener("focus", this.onFocus, {
              passive: true,
            });
            this.trigger.addEventListener("blur", this.onBlur, {
              passive: true,
            });
            break;
          case "focusin":
            this.trigger.addEventListener("focusin", this.onFocusIn, {
              passive: true,
            });
            this.trigger.addEventListener("focusout", this.onFocusOut, {
              passive: true,
            });
            break;
          case "hover":
            this.trigger.addEventListener("mousemove", this.onMouseMove, {
              passive: true,
            });
            if (!this.options.interactive) {
              this.trigger.addEventListener("mouseleave", this.onMouseLeave, {
                passive: true,
              });
            }

            break;
          case "click":
            this.trigger.addEventListener("click", this.onClick, {
              passive: true,
            });
            break;
        }
      });
  }

  get triggers() {
    return this.options.triggers ?? ["click"];
  }

  get untriggers() {
    return this.options.untriggers ?? ["click"];
  }
}
