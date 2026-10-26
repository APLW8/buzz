import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { render, waitFor, cleanup, act } from "@testing-library/react";
import {
  CommunityOnboardingProvider,
  useCommunityOnboarding,
  startCommunityOnboarding,
} from "./communityOnboarding.tsx";
import { useClaimInvite } from "./useClaimInvite.ts";

let controls;
function Claim() {
  controls = useCommunityOnboarding();
  useClaimInvite();
  return null;
}
const policy = {
  version: "v1",
  terms_markdown: "Terms",
  age_attestation_required: false,
};
const tauri = {
  invoke: async (command) => {
    if (command === "sign_event")
      return JSON.stringify({ id: "signed", tags: [] });
    throw new Error(`Unexpected command ${command}`);
  },
};
window.__TAURI_INTERNALS__ = tauri;
globalThis.__TAURI_INTERNALS__ = tauri;

for (const configured of [true, false]) {
  test(`receipt-less invite ${configured ? "waits for native consent" : "claims a policy-free relay"}`, async () => {
    localStorage.clear();
    const requests = [];
    const original = globalThis.fetch;
    globalThis.fetch = async (url) => {
      requests.push(String(url));
      if (String(url).endsWith("/api/join-policy"))
        return Response.json(configured ? { policy } : {});
      return Response.json({
        status: "joined",
        community_id: "id",
        host: "relay.example",
        role: "member",
      });
    };
    try {
      startCommunityOnboarding({
        source: "deep-link-join",
        relayUrl: "wss://relay.example",
        inviteCode: "code",
      });
      render(
        React.createElement(
          CommunityOnboardingProvider,
          null,
          React.createElement(Claim),
        ),
      );
      await waitFor(() =>
        assert.equal(
          controls.transaction.stage,
          configured ? "invite-consent" : "connecting",
        ),
      );
      assert.equal(
        requests.filter((url) => url.endsWith("/claim")).length,
        configured ? 0 : 1,
      );
    } finally {
      cleanup();
      globalThis.fetch = original;
    }
  });
}

test("rejected receipt returns to native consent and clears the stale proof", async () => {
  localStorage.clear();
  const original = globalThis.fetch;
  globalThis.fetch = async () =>
    Response.json({ error: "join_policy_required" }, { status: 403 });
  try {
    startCommunityOnboarding({
      source: "deep-link-join",
      relayUrl: "wss://relay.example",
      inviteCode: "code",
      policyReceipt: "expired",
    });
    render(
      React.createElement(
        CommunityOnboardingProvider,
        null,
        React.createElement(Claim),
      ),
    );
    await waitFor(() =>
      assert.equal(controls.transaction.stage, "invite-consent"),
    );
    assert.equal(controls.transaction.policyReceipt, undefined);
    assert.equal(controls.transaction.error, undefined);
  } finally {
    cleanup();
    globalThis.fetch = original;
  }
});

test("policy lookup failure never claims and can be retried", async () => {
  localStorage.clear();
  const original = globalThis.fetch;
  let failed = true;
  let claims = 0;
  globalThis.fetch = async (url) => {
    if (String(url).endsWith("/api/join-policy")) {
      if (failed) throw new Error("offline");
      return Response.json({ policy });
    }
    claims++;
    throw new Error("unexpected claim");
  };
  try {
    startCommunityOnboarding({
      source: "deep-link-join",
      relayUrl: "wss://relay.example",
      inviteCode: "code",
    });
    render(
      React.createElement(
        CommunityOnboardingProvider,
        null,
        React.createElement(Claim),
      ),
    );
    await waitFor(() => assert.equal(controls.transaction.error, "offline"));
    failed = false;
    await act(async () => controls.update({ error: undefined }));
    await waitFor(() =>
      assert.equal(controls.transaction.stage, "invite-consent"),
    );
    assert.equal(claims, 0);
  } finally {
    cleanup();
    globalThis.fetch = original;
  }
});

test("cancelled policy discovery cannot claim after its response arrives", async () => {
  localStorage.clear();
  const original = globalThis.fetch;
  let resolvePolicy;
  let started;
  const lookupStarted = new Promise((resolve) => {
    started = resolve;
  });
  const response = new Promise((resolve) => {
    resolvePolicy = resolve;
  });
  let claims = 0;
  globalThis.fetch = async (url) => {
    if (String(url).endsWith("/api/join-policy")) {
      started();
      return response;
    }
    claims++;
    throw new Error("unexpected claim");
  };
  try {
    startCommunityOnboarding({
      source: "deep-link-join",
      relayUrl: "wss://relay.example",
      inviteCode: "code",
    });
    render(
      React.createElement(
        CommunityOnboardingProvider,
        null,
        React.createElement(Claim),
      ),
    );
    await lookupStarted;
    await act(async () => controls.clear());
    await act(async () => resolvePolicy(Response.json({})));
    assert.equal(controls.transaction, null);
    assert.equal(claims, 0);
  } finally {
    cleanup();
    globalThis.fetch = original;
  }
});
