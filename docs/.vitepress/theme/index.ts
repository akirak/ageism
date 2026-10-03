import DefaultTheme from "vitepress/theme";
import { h } from "vue";
import MermaidZoom from "./MermaidZoom.vue";

export default {
	extends: DefaultTheme,
	Layout: () =>
		h(DefaultTheme.Layout, null, {
			"layout-bottom": () => h(MermaidZoom),
		}),
};
