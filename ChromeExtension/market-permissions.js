let ready;

export function enableMarketHeaders() {
  ready ??= navigator.locks.request("funddesk-market-rules", async () => {
    const source = await fetch(chrome.runtime.getURL("market-rules.json"));
    if (!source.ok) throw new Error("无法读取行情请求配置");
    const rules = (await source.json()).map(rule => ({
      ...rule,
      condition: {...rule.condition, initiatorDomains: [chrome.runtime.id]}
    }));
    const previous = await chrome.declarativeNetRequest.getDynamicRules();
    // Chrome normalizes some rule fields on read; replace the full set as one update.
    await chrome.declarativeNetRequest.updateDynamicRules({
      removeRuleIds: previous.map(rule => rule.id), addRules: rules
    });
  }).catch(error => {
    ready = undefined;
    throw error;
  });
  return ready;
}
