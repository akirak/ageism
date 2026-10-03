import DefaultTheme from "vitepress/theme";
import { h } from "vue";
import Mermaid from "./Mermaid.vue";
import MermaidZoom from "./MermaidZoom.vue";

export default {
	extends: DefaultTheme,
	Layout: () =>
		h(DefaultTheme.Layout, null, {
			"layout-bottom": () => h(MermaidZoom),
		}),
	enhanceApp({ app }) {
		app.component("Mermaid", Mermaid);
	},
};
