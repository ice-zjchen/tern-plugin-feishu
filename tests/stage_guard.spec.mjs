import assert from 'node:assert/strict';
import test from 'node:test';
import { install } from '../src/services/stage_guard.mjs';

function runtime(purpose, initial = ['bash', 'read', 'eval', 'mcp__business_write']) {
	const hooks = new Map();
	let active = [...initial];
	let updates = 0;
	const api = {
		on: (event, handler) => hooks.set(event, handler),
		getActiveTools: () => [...active],
		setActiveTools: async names => { active = [...names]; updates++; },
	};
	install(api, purpose, `isolated ${purpose} system`);
	return {
		hooks, api,
		active: () => [...active], updates: () => updates,
		reactivate: name => active.push(name),
		call: (toolName, input = {}) => hooks.get('tool_call')({ toolName, input }),
	};
}

test('vision removes every tool and blocks late discovered business capabilities', async () => {
	const run = runtime('vision');
	await run.hooks.get('session_start')();
	assert.deepEqual(run.active(), []);
	for (const name of ['read', 'eval', 'bash', 'mcp__business_write', 'custom_tool']) {
		run.reactivate(name);
		assert.equal(run.call(name).block, true);
	}
	const result = await run.hooks.get('before_agent_start')({ systemPrompt: 'ambient MCP instructions' });
	assert.deepEqual(run.active(), []);
	assert.equal(result.systemPrompt, 'isolated vision system');
});

test('relevance admits only the real judge dispatch tools and documentation', async () => {
	const run = runtime('relevance');
	await run.hooks.get('session_start')();
	assert.deepEqual(run.active(), ['eval', 'read']);
	assert.equal(run.call('eval', { language: 'js', code: 'const answer = await judge(state, questions); print(JSON.stringify(answer));' }), undefined);
	assert.equal(run.call('read', { path: 'xd://eval/judge' }), undefined);
	for (const path of ['/workflow/AGENTS.md', '/workflow/memory.md', 'skill://business', 'xd://mcp__business_write']) {
		assert.equal(run.call('read', { path }).block, true);
	}
	assert.equal(run.call('eval', { language: 'py', code: 'print(1)' }).block, true);
	assert.equal(run.call('mcp__business_write').block, true);
	assert.equal(run.call('bash').block, true);
});

test('MCP reactivation is fenced again before the next request, without a prompt-base retry loop', async () => {
	const run = runtime('relevance', ['eval', 'read']);
	await run.hooks.get('session_start')();
	assert.equal(run.updates(), 0);
	run.reactivate('mcp__late_tool');
	assert.equal(run.call('mcp__late_tool').block, true);
	await run.hooks.get('before_agent_start')();
	assert.deepEqual(run.active(), ['eval', 'read']);
	assert.equal(run.updates(), 1);
	await run.hooks.get('before_agent_start')();
	assert.equal(run.updates(), 1);
});

test('guard does not silently accept a missing stage or dedicated system prompt', () => {
	const api = { on: () => { throw new Error('must validate before registering'); } };
	for (const purpose of [undefined, 'analysis', 'chat', 'task']) {
		assert.throws(() => install(api, purpose, 'isolated system'), /Invalid Feishu/);
	}
	for (const system of [undefined, '', '   ']) {
		assert.throws(() => install(api, 'vision', system), /Invalid Feishu/);
	}
});
