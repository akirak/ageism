<script setup lang="ts">
import { useData } from "vitepress";
import { onMounted, ref, useId, watch } from "vue";

const props = defineProps<{ code: string }>();

const { isDark } = useData();
const id = `mermaid-${useId()}`;
const svg = ref("");

async function render() {
	const { default: mermaid } = await import("mermaid");
	mermaid.initialize({
		startOnLoad: false,
		theme: isDark.value ? "dark" : "default",
	});
	const result = await mermaid.render(id, decodeURIComponent(props.code));
	svg.value = result.svg;
}

onMounted(render);
watch(isDark, render);
</script>

<template>
	<div class="mermaid" v-html="svg" />
</template>
