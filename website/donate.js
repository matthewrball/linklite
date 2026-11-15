(function () {
  "use strict";

  var LIGHTNING_ADDRESS = "matthewrball@strike.me";
  var CASHAPP_LNURL = "https://strike.me/.well-known/lnurlp/matthewrball";
  var CASHAPP_LAUNCH = "https://cash.app/launch/lightning/";
  var BITCOIN_PANEL_MS = 260;
  var CASHAPP_PANEL_MS = 240;
  var DONATE_PANEL_MS = 500;
  var SIGNUP_DELAY_MS = 2500;
  var DOWNLOAD_VISITED_KEY = "linklite_download_visited";
  var reduceMotion = window.matchMedia
    ? window.matchMedia("(prefers-reduced-motion: reduce)")
    : { matches: false };
  var nextFrame = window.requestAnimationFrame || function (callback) {
    return window.setTimeout(callback, 0);
  };

  function focusElement(element) {
    if (!element || !element.focus) return;
    try { element.focus({ preventScroll: true }); }
    catch (_) { element.focus(); }
  }

  function later(callback, milliseconds) {
    return window.setTimeout(callback, reduceMotion.matches ? 0 : milliseconds);
  }

  function isOpen(panel) {
    return panel && panel.getAttribute("aria-hidden") === "false";
  }

  function focusableElements(root) {
    if (!root) return [];
    return Array.prototype.slice.call(root.querySelectorAll(
      'a[href], button:not([disabled]), input:not([disabled]), [tabindex]:not([tabindex="-1"])'
    )).filter(function (element) {
      return element.tabIndex >= 0 &&
        !element.closest("[inert]") &&
        element.getClientRects().length &&
        window.getComputedStyle(element).visibility !== "hidden";
    });
  }

  /* Donation drawer and nested wallet panels. */
  var donateDialog = document.getElementById("linklite-donate-dialog");

  if (donateDialog) {
    var donateSheet = donateDialog.querySelector("[data-linklite-donate-sheet]");
    var donateBase = donateDialog.querySelector("[data-linklite-donate-base]");
    var donateClose = donateDialog.querySelector("[data-linklite-close-donate]");
    var bitcoinPanel = document.getElementById("linklite-bitcoin-panel");
    var bitcoinBase = bitcoinPanel.querySelector("[data-linklite-bitcoin-base]");
    var cashAppPanel = document.getElementById("linklite-cashapp-panel");
    var cashAppStatus = cashAppPanel.querySelector("[data-linklite-cashapp-status]");
    var cashAppCustomSats = cashAppPanel.querySelector("[data-linklite-cashapp-custom-sats]");
    var lightningCopy = bitcoinPanel.querySelector("[data-linklite-copy-lightning]");
    var copyFeedback = bitcoinPanel.querySelector("[data-linklite-copy-feedback]");
    var donateLastFocus = null;
    var bitcoinLastFocus = null;
    var cashAppLastFocus = null;
    var donateTimer = null;
    var bitcoinTimer = null;
    var cashAppTimer = null;
    var cashAppBusy = false;
    var cashAppLnurlConfig = null;
    var cashAppRequestId = 0;
    var nativeModal = false;
    var fallbackInertState = [];

    function setFallbackPageInert(on) {
      if (on) {
        fallbackInertState = [];
        Array.prototype.forEach.call(document.body.children, function (element) {
          if (element === donateDialog) return;
          fallbackInertState.push({ element: element, inert: element.hasAttribute("inert") });
          element.setAttribute("inert", "");
        });
      } else {
        fallbackInertState.forEach(function (entry) {
          if (!entry.inert) entry.element.removeAttribute("inert");
        });
        fallbackInertState = [];
      }
    }

    function setCopyStatus(text, announcement) {
      lightningCopy.textContent = text || "Copy";
      copyFeedback.textContent = announcement || "";
    }

    function setCashAppStatus(text) {
      cashAppStatus.textContent = text || "Choose sats to create a Lightning invoice";
    }

    function setCashAppBusy(on) {
      cashAppBusy = !!on;
      cashAppPanel.setAttribute("aria-busy", on ? "true" : "false");
      cashAppPanel.querySelectorAll(
        "[data-linklite-cashapp-sats], [data-linklite-cashapp-custom] input, [data-linklite-cashapp-custom] button"
      ).forEach(function (control) { control.disabled = !!on; });
    }

    function selectCashAppAmount(amount) {
      cashAppPanel.querySelectorAll("[data-linklite-cashapp-sats]").forEach(function (button) {
        var selected = button.getAttribute("data-linklite-cashapp-sats") === String(amount || "");
        button.classList.toggle("linklite-is-selected", selected);
        button.setAttribute("aria-pressed", selected ? "true" : "false");
      });
    }

    function resetCashAppState() {
      cashAppRequestId += 1;
      if (cashAppTimer !== null) {
        window.clearTimeout(cashAppTimer);
        cashAppTimer = null;
      }
      setCashAppBusy(false);
      setCashAppStatus();
      selectCashAppAmount("");
      cashAppCustomSats.value = "";
      bitcoinPanel.classList.remove("linklite-is-cashapp-open");
      bitcoinBase.removeAttribute("inert");
      cashAppPanel.classList.remove("linklite-is-open");
      cashAppPanel.setAttribute("aria-hidden", "true");
      cashAppPanel.setAttribute("inert", "");
    }

    function resetBitcoinState() {
      if (bitcoinTimer !== null) {
        window.clearTimeout(bitcoinTimer);
        bitcoinTimer = null;
      }
      donateSheet.classList.remove("linklite-is-bitcoin-open");
      donateBase.removeAttribute("inert");
      bitcoinPanel.classList.remove("linklite-is-open", "linklite-is-cashapp-open");
      bitcoinPanel.setAttribute("aria-hidden", "true");
      bitcoinPanel.setAttribute("inert", "");
      setCopyStatus("Copy");
      resetCashAppState();
    }

    function openDonate() {
      if (donateDialog.open) return;
      donateLastFocus = document.activeElement;
      if (donateTimer !== null) {
        window.clearTimeout(donateTimer);
        donateTimer = null;
      }
      resetBitcoinState();
      donateDialog.classList.remove("linklite-is-shown", "linklite-is-closing");
      nativeModal = false;
      if (typeof donateDialog.showModal === "function") {
        try {
          donateDialog.showModal();
          nativeModal = true;
        } catch (_) { /* Use the trapped, inert fallback below. */ }
      }
      if (!nativeModal) {
        donateDialog.setAttribute("open", "");
        donateDialog.setAttribute("aria-modal", "true");
        setFallbackPageInert(true);
      }
      nextFrame(function () { donateDialog.classList.add("linklite-is-shown"); });
      focusElement(donateClose);
    }

    function closeDonate() {
      if (!donateDialog.open || donateDialog.classList.contains("linklite-is-closing")) return;
      resetBitcoinState();
      donateDialog.classList.remove("linklite-is-shown");
      donateDialog.classList.add("linklite-is-closing");
      donateTimer = later(function () {
        try { donateDialog.close(); }
        catch (_) { donateDialog.removeAttribute("open"); }
        if (!nativeModal) {
          donateDialog.removeAttribute("aria-modal");
          setFallbackPageInert(false);
        }
        donateDialog.classList.remove("linklite-is-closing");
        focusElement(donateLastFocus);
        donateTimer = null;
      }, DONATE_PANEL_MS);
    }

    function openBitcoinPanel() {
      if (!donateDialog.open || isOpen(bitcoinPanel)) return;
      bitcoinLastFocus = document.activeElement;
      if (bitcoinTimer !== null) {
        window.clearTimeout(bitcoinTimer);
        bitcoinTimer = null;
      }
      resetCashAppState();
      donateBase.setAttribute("inert", "");
      donateSheet.classList.add("linklite-is-bitcoin-open");
      bitcoinPanel.removeAttribute("inert");
      bitcoinPanel.setAttribute("aria-hidden", "false");
      nextFrame(function () {
        bitcoinPanel.classList.add("linklite-is-open");
        focusElement(lightningCopy);
      });
    }

    function closeBitcoinPanel() {
      if (!isOpen(bitcoinPanel)) return;
      resetCashAppState();
      donateSheet.classList.remove("linklite-is-bitcoin-open");
      bitcoinPanel.classList.remove("linklite-is-open");
      bitcoinTimer = later(function () {
        bitcoinPanel.setAttribute("aria-hidden", "true");
        bitcoinPanel.setAttribute("inert", "");
        donateBase.removeAttribute("inert");
        setCopyStatus("Copy");
        if (donateDialog.open) focusElement(bitcoinLastFocus);
        bitcoinTimer = null;
      }, BITCOIN_PANEL_MS);
    }

    function openCashAppPanel() {
      if (!isOpen(bitcoinPanel) || isOpen(cashAppPanel)) return;
      cashAppLastFocus = document.activeElement;
      if (cashAppTimer !== null) {
        window.clearTimeout(cashAppTimer);
        cashAppTimer = null;
      }
      bitcoinBase.setAttribute("inert", "");
      bitcoinPanel.classList.add("linklite-is-cashapp-open");
      cashAppPanel.removeAttribute("inert");
      cashAppPanel.setAttribute("aria-hidden", "false");
      nextFrame(function () {
        cashAppPanel.classList.add("linklite-is-open");
        focusElement(cashAppPanel.querySelector("[data-linklite-cashapp-sats]"));
      });
    }

    function closeCashAppPanel() {
      if (!isOpen(cashAppPanel)) return;
      cashAppRequestId += 1;
      bitcoinPanel.classList.remove("linklite-is-cashapp-open");
      cashAppPanel.classList.remove("linklite-is-open");
      cashAppTimer = later(function () {
        resetCashAppState();
        if (donateDialog.open) focusElement(cashAppLastFocus);
        cashAppTimer = null;
      }, CASHAPP_PANEL_MS);
    }

    function closeTopPanel() {
      if (isOpen(cashAppPanel)) closeCashAppPanel();
      else if (isOpen(bitcoinPanel)) closeBitcoinPanel();
      else closeDonate();
    }

    function selectLightningAddress() {
      var code = bitcoinPanel.querySelector("[data-linklite-lightning-address]");
      if (!code || !window.getSelection || !document.createRange) return;
      var range = document.createRange();
      range.selectNodeContents(code);
      var selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }

    function fallbackCopyLightningAddress() {
      var previousFocus = document.activeElement;
      var textarea = document.createElement("textarea");
      textarea.value = LIGHTNING_ADDRESS;
      textarea.setAttribute("readonly", "");
      textarea.style.position = "fixed";
      textarea.style.left = "-9999px";
      document.body.appendChild(textarea);
      textarea.select();
      var copied = false;
      try {
        copied = typeof document.execCommand === "function" && document.execCommand("copy");
      } catch (_) { /* Selection fallback is reported below. */ }
      textarea.remove();
      focusElement(previousFocus);
      return copied ? Promise.resolve() : Promise.reject(new Error("Copy unavailable"));
    }

    function copyLightningAddress() {
      try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          return navigator.clipboard.writeText(LIGHTNING_ADDRESS).catch(fallbackCopyLightningAddress);
        }
      } catch (_) { /* Fall through to the selection-based copy path. */ }
      return fallbackCopyLightningAddress();
    }

    function showCopySuccess() {
      setCopyStatus("Copied", "Lightning address copied.");
    }

    function showCopyFallback() {
      selectLightningAddress();
      setCopyStatus("Selected", "Copy unavailable. The Lightning address is selected; press Command or Control plus C.");
    }

    function strikeCallback(value) {
      try {
        var url = new URL(value);
        return url.protocol === "https:" &&
          (url.hostname === "strike.me" || url.hostname.endsWith(".strike.me")) ? url : null;
      } catch (_) {
        return null;
      }
    }

    function getCashAppLnurlConfig() {
      if (cashAppLnurlConfig) return Promise.resolve(cashAppLnurlConfig);
      if (!window.fetch) return Promise.reject(new Error("Network unavailable"));
      return fetch(CASHAPP_LNURL, { credentials: "omit", redirect: "error" }).then(function (response) {
        if (!response.ok) throw new Error("Lightning configuration unavailable");
        return response.json();
      }).then(function (data) {
        if (!data || data.status !== "OK" || !strikeCallback(data.callback) ||
            !Number.isFinite(data.minSendable) || !Number.isFinite(data.maxSendable) ||
            data.minSendable <= 0 || data.maxSendable < data.minSendable) {
          throw new Error("Invalid Lightning configuration");
        }
        cashAppLnurlConfig = data;
        return data;
      });
    }

    function getCashAppInvoice(sats) {
      var millisats = sats * 1000;
      return getCashAppLnurlConfig().then(function (data) {
        if (millisats < data.minSendable || millisats > data.maxSendable) {
          throw new Error("Amount out of range");
        }
        var callback = strikeCallback(data.callback);
        if (!callback) throw new Error("Invalid Lightning callback");
        callback.searchParams.set("amount", String(millisats));
        return fetch(callback.href, { credentials: "omit", redirect: "error" });
      }).then(function (response) {
        if (!response.ok) throw new Error("Invoice unavailable");
        return response.json();
      }).then(function (data) {
        if (!data || typeof data.pr !== "string" || !data.pr) throw new Error("Invoice missing");
        return data.pr;
      });
    }

    function parseSats(value) {
      var sats = Number(String(value || "").trim());
      if (!Number.isFinite(sats)) return 0;
      sats = Math.floor(sats);
      return Number.isSafeInteger(sats) && sats > 0 && sats <= Math.floor(Number.MAX_SAFE_INTEGER / 1000)
        ? sats
        : 0;
    }

    function openCashAppInvoice(value) {
      if (cashAppBusy || !isOpen(cashAppPanel)) return;
      var sats = parseSats(value);
      if (!sats) {
        setCashAppStatus("Enter a valid whole number of sats first.");
        focusElement(cashAppCustomSats);
        return;
      }
      var requestId = ++cashAppRequestId;
      selectCashAppAmount(sats);
      setCashAppBusy(true);
      setCashAppStatus("Creating invoice…");
      getCashAppInvoice(sats).then(function (invoice) {
        if (requestId !== cashAppRequestId || !isOpen(cashAppPanel)) return;
        setCashAppStatus("Opening Cash App…");
        try {
          window.location.assign(CASHAPP_LAUNCH + encodeURIComponent(invoice));
        } catch (_) {
          setCashAppStatus("Could not open Cash App. Try again.");
        }
      }).catch(function (error) {
        if (requestId !== cashAppRequestId) return;
        selectCashAppAmount("");
        setCashAppStatus(error && error.message === "Amount out of range"
          ? "Amount is out of the recipient’s accepted range."
          : "Could not create an invoice. Check your connection and try again.");
      }).then(function () {
        if (requestId === cashAppRequestId) setCashAppBusy(false);
      });
    }

    document.querySelectorAll("[data-open-donate]").forEach(function (button) {
      button.addEventListener("click", function (event) {
        event.preventDefault();
        openDonate();
      });
    });
    donateClose.addEventListener("click", closeDonate);
    donateDialog.querySelectorAll("[data-linklite-open-bitcoin]").forEach(function (button) {
      button.addEventListener("click", openBitcoinPanel);
    });
    donateDialog.querySelectorAll("[data-linklite-close-bitcoin]").forEach(function (button) {
      button.addEventListener("click", closeBitcoinPanel);
    });
    donateDialog.querySelectorAll("[data-linklite-open-cashapp]").forEach(function (button) {
      button.addEventListener("click", openCashAppPanel);
    });
    donateDialog.querySelectorAll("[data-linklite-close-cashapp]").forEach(function (button) {
      button.addEventListener("click", closeCashAppPanel);
    });
    donateDialog.querySelectorAll("[data-linklite-copy-lightning]").forEach(function (button) {
      button.addEventListener("click", function () {
        copyLightningAddress().then(showCopySuccess).catch(showCopyFallback);
      });
    });
    donateDialog.querySelectorAll("[data-linklite-copy-before-open]").forEach(function (link) {
      link.addEventListener("click", function (event) {
        var href = link.getAttribute("href") || "";
        var opensApp = /^[a-z][a-z0-9+.-]*:/i.test(href) && !/^https?:/i.test(href);
        if (opensApp) event.preventDefault();
        copyLightningAddress().then(showCopySuccess).catch(showCopyFallback).then(function () {
          if (opensApp) {
            try { window.location.assign(href); }
            catch (_) { copyFeedback.textContent = "Could not open BlueWallet. Copy the address and open it from your wallet."; }
          }
        });
      });
    });
    cashAppPanel.querySelectorAll("[data-linklite-cashapp-sats]").forEach(function (button) {
      button.addEventListener("click", function () {
        cashAppCustomSats.value = "";
        openCashAppInvoice(button.getAttribute("data-linklite-cashapp-sats"));
      });
    });
    cashAppPanel.querySelector("[data-linklite-cashapp-custom]").addEventListener("submit", function (event) {
      event.preventDefault();
      openCashAppInvoice(cashAppCustomSats.value);
    });

    donateDialog.addEventListener("cancel", function (event) {
      event.preventDefault();
      closeTopPanel();
    });
    donateDialog.addEventListener("click", function (event) {
      if (event.target === donateDialog) closeDonate();
    });
    donateDialog.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && !nativeModal) {
        event.preventDefault();
        closeTopPanel();
        return;
      }
      if (event.key !== "Tab") return;
      var root = isOpen(cashAppPanel) ? cashAppPanel : (isOpen(bitcoinPanel) ? bitcoinPanel : donateDialog);
      var controls = focusableElements(root);
      if (!controls.length) {
        event.preventDefault();
        return;
      }
      var first = controls[0];
      var last = controls[controls.length - 1];
      if (event.shiftKey && (document.activeElement === first || !root.contains(document.activeElement))) {
        event.preventDefault();
        focusElement(last);
      } else if (!event.shiftKey && (document.activeElement === last || !root.contains(document.activeElement))) {
        event.preventDefault();
        focusElement(first);
      }
    });
  }

  /* Signup banner: the reference's 2.5-second, download-aware behavior. */
  var signupBanner = document.querySelector("[data-linklite-signup-banner]");

  if (signupBanner) {
    var signupForm = signupBanner.querySelector("[data-linklite-signup-form]");
    var signupEmail = signupForm.querySelector('input[type="email"]');
    var signupButton = signupForm.querySelector("[data-linklite-signup-submit]");
    var signupStatus = signupBanner.querySelector("[data-linklite-signup-status]");
    var signupPage = signupBanner.getAttribute("data-linklite-signup-banner");
    var signupTimer = null;
    var signupUnavailable = false;
    var turnstilePromise = null;

    function hasVisitedDownload() {
      try { return window.localStorage.getItem(DOWNLOAD_VISITED_KEY) === "1"; }
      catch (_) { return false; }
    }

    function showSignupIfEligible() {
      if (signupPage !== "download" && !(signupPage === "home" && hasVisitedDownload())) return;
      signupBanner.hidden = true;
      if (signupTimer !== null) window.clearTimeout(signupTimer);
      signupTimer = window.setTimeout(function () {
        signupBanner.hidden = false;
        signupTimer = null;
      }, SIGNUP_DELAY_MS);
    }

    if (signupPage === "download") {
      try { window.localStorage.setItem(DOWNLOAD_VISITED_KEY, "1"); }
      catch (_) { /* Showing the download-page banner still works without storage. */ }
    }

    document.addEventListener("click", function (event) {
      if (!event.target || !event.target.closest) return;
      var download = event.target.closest('a[href^="https://github.com/matthewrball/linklite/releases/download/"]');
      if (!download) return;
      try { window.localStorage.setItem(DOWNLOAD_VISITED_KEY, "1"); }
      catch (_) { /* A blocked storage API must not block the download. */ }
    }, true);

    signupBanner.querySelector("[data-linklite-signup-dismiss]").addEventListener("click", function () {
      if (signupTimer !== null) {
        window.clearTimeout(signupTimer);
        signupTimer = null;
      }
      signupBanner.hidden = true;
    });

    function loadTurnstile() {
      if (window.turnstile) return Promise.resolve();
      if (turnstilePromise) return turnstilePromise;
      turnstilePromise = new Promise(function (resolve, reject) {
        var script = document.createElement("script");
        script.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
        script.async = true;
        script.onload = function () {
          if (window.turnstile) resolve();
          else reject(new Error("Signup verification is unavailable."));
        };
        script.onerror = function () { reject(new Error("Signup verification is unavailable.")); };
        document.head.appendChild(script);
      });
      return turnstilePromise;
    }

    function prepareSignupChallenge() {
      var container = signupForm.querySelector("[data-linklite-signup-challenge]");
      if (!window.fetch || !container) return Promise.reject(new Error("Signup is unavailable."));
      return fetch("/api/signup", { headers: { "Accept": "application/json" } }).then(function (response) {
        if (!response.ok) throw new Error("Signup is unavailable.");
        return response.json();
      }).then(function (data) {
        if (!data || typeof data.siteKey !== "string" || !data.siteKey) {
          throw new Error("Signup is unavailable.");
        }
        return loadTurnstile().then(function () {
          var token = "";
          var widgetId = window.turnstile.render(container, {
            sitekey: data.siteKey,
            action: "signup",
            appearance: "interaction-only",
            theme: "dark",
            callback: function (value) { token = value; },
            "expired-callback": function () { token = ""; },
            "error-callback": function () { token = ""; }
          });
          return function () {
            return token || window.turnstile.getResponse(widgetId) || "";
          };
        });
      });
    }

    var signupChallenge = prepareSignupChallenge().catch(function (error) {
      signupUnavailable = true;
      signupButton.disabled = true;
      signupStatus.textContent = error.message || "Signup is unavailable.";
      return function () { throw error; };
    });

    signupEmail.addEventListener("input", function () {
      signupEmail.removeAttribute("aria-invalid");
    });

    signupForm.addEventListener("submit", function (event) {
      event.preventDefault();
      if (signupUnavailable || signupButton.disabled) return;
      if (!signupForm.checkValidity()) {
        signupEmail.setAttribute("aria-invalid", "true");
        signupStatus.textContent = "Enter a valid email address.";
        signupForm.reportValidity();
        focusElement(signupEmail);
        return;
      }

      signupButton.disabled = true;
      signupForm.setAttribute("aria-busy", "true");
      signupStatus.textContent = "Signing you up…";

      signupChallenge.then(function (getToken) {
        var turnstileToken = getToken();
        if (!turnstileToken) throw new Error("Confirm you’re human and try again.");
        var fields = Object.fromEntries(new FormData(signupForm));
        fields.turnstileToken = turnstileToken;
        return fetch("/api/signup", {
          method: "POST",
          headers: { "Content-Type": "application/json", "Accept": "application/json" },
          body: JSON.stringify(fields)
        }).catch(function () {
          throw new Error("Could not sign you up. Check your connection and try again.");
        });
      }).then(function (response) {
        if (!response) return;
        return response.json().catch(function () {
          throw new Error("Signup returned an invalid response. Try again.");
        }).then(function (result) {
          if (!response.ok || !result || result.ok !== true) {
            throw new Error(result && typeof result.error === "string" && result.error
              ? result.error
              : "Could not sign you up. Try again.");
          }
          signupForm.hidden = true;
          signupStatus.textContent = "You’re on the list. Thank you.";
        });
      }).catch(function (error) {
        signupStatus.textContent = error.message || "Could not sign you up. Try again.";
        if (!signupUnavailable) signupButton.disabled = false;
      }).then(function () {
        signupForm.setAttribute("aria-busy", "false");
      });
    });

    showSignupIfEligible();
    window.addEventListener("pageshow", function (event) {
      if (event.persisted) showSignupIfEligible();
    });
  }
})();
