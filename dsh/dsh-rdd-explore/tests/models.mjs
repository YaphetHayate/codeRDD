#!/usr/bin/env node
// models-tool catalog test (run after `npm run build`: node tests/models.mjs).
//
// Covers collectCatalog's projection and failure semantics — no cordis
// composition needed: the catalog face is structural, so a fake source drives
// every case:
//   - per-route model projection (provider/id/name passthrough, optional
//     description and inputModalities copied only when present)
//   - per-route failure isolation (one rejecting route never fails the call;
//     Error instances surface .message, non-Errors are stringified)
//   - the empty-catalog case (no registered routes -> empty providers, the
//     "inherit-only" state the rendered text frames for the model)
//   - renderCatalog text: pair-together guidance, vision annotation, and the
//     failed-route warning
// @module @coderrdd/dsh-rdd-explore/models-test

import { collectCatalog, renderCatalog } from '../lib/models.js'

let failures = 0
const check = (name, condition, detail = '') => {
  const ok = condition === true
  if (!ok) failures += 1
  console.log(`${ok ? 'ok' : 'FAIL'} - ${name}${ok || detail === '' ? '' : ` :: ${detail}`}`)
}

const deepEqual = (actual, expected) => JSON.stringify(actual) === JSON.stringify(expected)

/** A fake catalog source over scripted routes. */
function fakeSource(routes) {
  return {
    listProviders: () => routes.map(route => ({ id: route.provider, name: route.name })),
    listModels: async provider => {
      const route = routes.find(candidate => candidate.provider === provider)
      if (route === undefined) throw new Error(`unknown route ${provider}`)
      if (route.reject !== undefined) throw route.reject
      return route.models
    },
  }
}

// --- projection: passthrough plus optional-field copying --------------------
{
  const catalog = await collectCatalog(fakeSource([
    {
      provider: 'deepseek-official',
      name: 'DeepSeek official',
      models: [
        { provider: 'deepseek-official', id: 'deepseek-v4-pro', name: 'DeepSeek-V4-Pro' },
        {
          provider: 'deepseek-official',
          id: 'deepseek-v4-flash-vision-exp',
          name: 'DeepSeek-V4-Flash-Vision-Exp',
          description: 'pre-release vision',
          inputModalities: ['text', 'image'],
        },
      ],
    },
  ]))
  check('sound route enumerates with its models', catalog.providers.length === 1 && catalog.failures.length === 0)
  const models = catalog.providers[0].models
  check('model without optionals omits both keys',
    !('description' in models[0]) && !('inputModalities' in models[0]), JSON.stringify(models[0]))
  check('model with optionals copies both values',
    models[1].description === 'pre-release vision' && deepEqual(models[1].inputModalities, ['text', 'image']),
    JSON.stringify(models[1]))
}

// --- failure isolation -------------------------------------------------------
{
  const catalog = await collectCatalog(fakeSource([
    {
      provider: 'sound-route',
      name: 'Sound',
      models: [{ provider: 'sound-route', id: 'm1', name: 'M1' }],
    },
    { provider: 'broken-route', name: 'Broken', reject: new Error('endpoint unreachable') },
    { provider: 'weird-route', name: 'Weird', reject: 'not even an Error' },
  ]))
  check('a rejecting route never fails the call', catalog.providers.length === 1 && catalog.providers[0].provider === 'sound-route')
  check('Error rejections surface .message',
    catalog.failures.some(failure => failure.provider === 'broken-route' && failure.message === 'endpoint unreachable'),
    JSON.stringify(catalog.failures))
  check('non-Error rejections are stringified',
    catalog.failures.some(failure => failure.provider === 'weird-route' && failure.message === 'not even an Error'),
    JSON.stringify(catalog.failures))
}

// --- empty catalog -----------------------------------------------------------
{
  const catalog = await collectCatalog(fakeSource([]))
  check('no registered routes -> empty providers, no failures',
    catalog.providers.length === 0 && catalog.failures.length === 0)
  const text = renderCatalog(catalog)
  check('empty-catalog render frames inherit-only, not an error',
    text.includes("follows the parent session's model"), text)
}

// --- render guidance ---------------------------------------------------------
{
  const text = renderCatalog({
    providers: [{
      provider: 'p1',
      name: 'Provider One',
      models: [
        { provider: 'p1', id: 'text-only', name: 'Text Only' },
        { provider: 'p1', id: 'vision', name: 'Vision', inputModalities: ['text', 'image'] },
      ],
    }],
    failures: [{ provider: 'dead-route', message: 'down' }],
  })
  check('render carries the pair-together dispatch guidance', text.includes('{ provider, id }'), text)
  check('render annotates vision capability', text.includes('text+image'), text)
  check('render warns about failed routes', text.includes('dead-route'), text)
}

process.exit(failures === 0 ? 0 : 1)
