/** Minimal JSON-RPC transport for embedded apps that supply their own UI.
 * Extension behavior belongs in the app's shared controller, not this transport.
 */









export function createAppTransport

 () {
  let sequence = 0;
  const pending = new Map






   ();
  const handlers = new Map                                      ();
  const listeners = new Map                                        ();
  const send = (message                             ) =>
    window.parent.postMessage({ jsonrpc: "2.0", ...message }, "*");
  const receive = async (event              ) => {
    if (event.source !== window.parent || event.data?.jsonrpc !== "2.0") return;
    const message             = event.data;
    if (!message.method && message.id != null) {
      const request = pending.get(message.id);
      if (!request) return;
      pending.delete(message.id);
      clearTimeout(request.timer);
      if (message.error) request.reject(new Error(message.error.message));
      else request.resolve(message.result);
    } else if (message.method && message.id != null) {
      const handler = handlers.get(message.method);
      if (!handler) {
        send({
          id: message.id,
          error: {
            code: -32601,
            message: `Unsupported app method: ${message.method}`,
          },
        });
        return;
      }
      try {
        send({
          id: message.id,
          result: await handler((message.params ?? {})           ),
        });
      } catch (error) {
        send({
          id: message.id,
          error: {
            code: -32603,
            message: error instanceof Error ? error.message : String(error),
          },
        });
      }
    } else if (message.method) {
      for (const listener of listeners.get(message.method) ?? [])
        listener((message.params ?? {})           );
    }
  };
  window.addEventListener("message", receive);
  return {
    request                  (
      method        ,
      params                          = {},
      timeoutMs = 15000,
    )                  {
      if (window.parent === window)
        return Promise.reject(
          new Error(`Open this app in an MCP host to use ${method}`),
        );
      const id = ++sequence;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`${method} timed out`));
        }, timeoutMs);
        pending.set(id, {
          resolve: (value) => resolve(value          ),
          reject,
          timer,
        });
        send({ id, method, params });
      });
    },
    notify(method        , params                          = {}) {
      send({ method, params });
    },
    handle(method        , handler                              ) {
      handlers.set(method, handler);
    },
    on(method        , listener                           ) {
      if (!listeners.has(method)) listeners.set(method, new Set());
      listeners.get(method) .add(listener);
      return () => {
        listeners.get(method)?.delete(listener);
      };
    },
    dispose() {
      window.removeEventListener("message", receive);
      for (const request of pending.values()) {
        clearTimeout(request.timer);
        request.reject(new Error("App disposed"));
      }
      pending.clear();
      handlers.clear();
      listeners.clear();
    },
  };
}
