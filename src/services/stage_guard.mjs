// --tools/--no-tools filter built-ins, not discovered MCP tools. This explicit
// extension fences the complete registry without changing the user's profile.
export function install(api, purpose, systemPrompt) {
	if (!['vision', 'relevance'].includes(purpose) || typeof systemPrompt !== 'string' || !systemPrompt.trim()) {
		throw new Error('Invalid Feishu isolated-stage configuration');
	}
	const allowed = purpose === 'relevance' ? ['eval', 'read'] : [];
	const constrain = async () => {
		const active = api.getActiveTools();
		if (active.length !== allowed.length || allowed.some(name => !active.includes(name))) {
			await api.setActiveTools(allowed);
		}
	};
	api.on('session_start', constrain);
	api.on('before_agent_start', async () => {
		await constrain();
		// The host's complete narrow prompt wins over ambient MCP instructions.
		return { systemPrompt };
	});
	api.on('tool_call', event => {
		if (!allowed.includes(event.toolName)) {
			return { block: true, reason: `Tool unavailable in Feishu ${purpose} stage: ${event.toolName}` };
		}
		// Relevance only reads the judge runtime's API, not business context,
		// project instructions, global memories, or arbitrary xd:// devices.
		if (event.toolName === 'read' && event.input?.path !== 'xd://eval/judge') {
			return { block: true, reason: 'Relevance may only read xd://eval/judge' };
		}
		if (event.toolName === 'eval' && event.input?.language !== 'js') {
			return { block: true, reason: 'Relevance judgment requires JavaScript eval' };
		}
	});
}

export default function stageGuard(api) {
	install(api, process.env.FEISHU_WORKBENCH_STAGE, process.env.FEISHU_WORKBENCH_SYSTEM_PROMPT);
}
