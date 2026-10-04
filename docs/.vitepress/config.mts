import { defineConfig } from "vitepress";

export default defineConfig({
	title: "ageism",
	description: "An age secret deployment tool for NixOS",
	base: "/ageism/",
	cleanUrls: true,
	lastUpdated: false,
	markdown: {
		config(md) {
			const fence = md.renderer.rules.fence;
			md.renderer.rules.fence = (tokens, idx, options, env, self) => {
				const token = tokens[idx];
				if (token.info.trim() === "mermaid") {
					const code = encodeURIComponent(token.content);
					return `<ClientOnly><Mermaid code="${code}" /></ClientOnly>`;
				}
				return fence(tokens, idx, options, env, self);
			};
		},
	},
	vite: {
		// Pre-bundle Mermaid with its CommonJS dependencies for the dev server.
		optimizeDeps: { include: ["mermaid"] },
	},
	themeConfig: {
		nav: [
			{ text: "Guide", link: "/guide/introduction" },
			{ text: "Reference", link: "/reference/cli" },
		],
		sidebar: [
			{
				text: "Guide",
				items: [
					{ text: "Introduction", link: "/guide/introduction" },
					{ text: "Installation", link: "/guide/installation" },
					{ text: "Getting started", link: "/guide/getting-started" },
					{
						text: "Generating a host key",
						link: "/guide/generating-a-key",
					},
					{ text: "How it works", link: "/guide/how-it-works" },
					{
						text: "Comparison with agenix-rekey",
						link: "/guide/comparison",
					},
					{ text: "NixOS module", link: "/guide/nixos-module" },
					{
						text: "systemd credentials",
						link: "/guide/systemd-credentials",
					},
				],
			},
			{
				text: "Reference",
				items: [
					{ text: "CLI", link: "/reference/cli" },
					{ text: "Index file", link: "/reference/index-file" },
				],
			},
		],
		socialLinks: [{ icon: "github", link: "https://github.com/akirak/ageism" }],
	},
});
