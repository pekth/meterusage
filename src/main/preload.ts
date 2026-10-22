import { contextBridge, ipcRenderer } from "electron";
import { channel, stateChannel, type Request, type ViewState } from "../shared/ipc";
contextBridge.exposeInMainWorld("meterusage", {
  request: (request: Request) => ipcRenderer.invoke(channel, request),
  subscribe: (observer: (state: ViewState) => void) => {
    const listener = (_event: unknown, state: ViewState) => observer(state);
    ipcRenderer.on(stateChannel, listener);
    return () => ipcRenderer.removeListener(stateChannel, listener);
  },
});
