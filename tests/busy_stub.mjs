// Shared busy-ownership stub for VM-extracted Panel handlers.
export function withBusyStubs(context) {
  context.busyOwner = "";
  context.acquireBusy = o => { context.busyOwner = o; context.busy = true; };
  context.releaseBusy = o => {
    if (context.busyOwner === o || !context.busyOwner) { context.busyOwner = ""; context.busy = false; }
  };
  return context;
}
