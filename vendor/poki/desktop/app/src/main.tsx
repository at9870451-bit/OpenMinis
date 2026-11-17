import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
if (import.meta.env.VITE_MOCK) await import("./mock");

ReactDOM.createRoot(document.getElementById("root")!).render(<React.StrictMode><App /></React.StrictMode>);
