import { defineConfig } from "vitepress";

export default defineConfig({
	title: "ageism",
	description: "An age secret deployment tool for NixOS",
	base: "/ageism/",
	cleanUrls: true,
	lastUpdated: false,
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
					{ text: "How it works", link: "/guide/how-it-works" },
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
