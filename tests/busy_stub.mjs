// Shared busy-ownership stub for VM-extracted Panel handlers. Mirrors
// Panel.qml's acquireBusy/releaseBusy: the flag is claimable when unowned or
// already owned by the same workflow, and a second workflow must never steal
// it. Acquire returns whether the claim was granted.
export function withBusyStubs(context) {
  context.busyOwner = "";
  context.acquireBusy = o => {
    if (context.busyOwner && context.busyOwner !== o) return false;
    context.busyOwner = o;
    context.busy = true;
    return true;
  };
  context.releaseBusy = o => {
    if (context.busyOwner === o || !context.busyOwner) { context.busyOwner = ""; context.busy = false; }
  };
  return context;
}
