/**
 * Runtime model-catalog discovery as one model-facing tool (`rdd_models`).
 *
 * The RDD UX flow needs "which models can I dispatch to RIGHT NOW" as a live
 * question — a statically configured model list drifts from the host the
 * moment a provider route is added, removed, or re-keyed. This tool reads the
 * host's own catalog face (`ctx.llm`: registered provider routes plus each
 * route's advertised models) and projects it for the model: every entry maps
 * 1:1 onto a delegation override pair, so a dispatch-time model choice is
 * "pick from this list, pass `{ provider, id }` through".
 *
 * Failure isolation follows the host wire contract (`llm.models`): one route
 * failing to enumerate never fails the call — the route lands in `failures`
 * and the sound groups still answer. A host with no registered routes returns
 * an empty catalog, which the rendered text frames as "inherit-only" rather
 * than an error.
 *
 * @module @coderrdd/dsh-rdd-explore/models
 */

import type { Context } from '@deepseek-ai/cordis'
import { defineTool } from '@deepseek-ai/dsh-tools'
import type { LlmModelInfo } from '@deepseek-ai/dsh-llm'

/**
 * The catalog face this tool reads — the structural slice of `LlmRuntime` it
 * calls. Structural on purpose: tests fake it without composing cordis.
 */
export interface ModelCatalogSource {
  /** Registered provider routes in registration order. */
  listProviders(): ReadonlyArray<{ id: string; name: string }>
  /** One route's advertised models; may reject (route-specific failure). */
  listModels(provider: string): Promise<readonly LlmModelInfo[]>
}

/** One selectable model, projected for the model. */
export interface ModelEntryView {
  /** Provider route key — the `provider` half of a delegation override pair. */
  provider: string
  /** Model id — the `model` half of a delegation override pair. */
  id: string
  /** Human-readable model name. */
  name: string
  /** Optional user-facing distinction, when the adapter published one. */
  description?: string
  /** Accepted request modalities ('text' / 'image'); absent means unknown. */
  inputModalities?: ('text' | 'image')[]
}

/** The tool's canonical output. */
export interface CatalogView {
  /** Successfully enumerated routes, each with its advertised models. */
  providers: Array<{ provider: string; name: string; models: ModelEntryView[] }>
  /** Routes that failed to enumerate, with their error text. */
  failures: Array<{ provider: string; message: string }>
}

/** Project one adapter model entry into the model-facing view. */
function modelView(model: LlmModelInfo): ModelEntryView {
  return {
    provider: model.provider,
    id: model.id,
    name: model.name,
    ...(model.description !== undefined ? { description: model.description } : {}),
    ...(model.inputModalities !== undefined ? { inputModalities: [...model.inputModalities] } : {}),
  }
}

/**
 * Enumerate every registered route's models, isolating per-route failures.
 * @param source - the host catalog face (`ctx.llm`).
 * @returns sound provider groups plus per-route failures.
 */
export async function collectCatalog(source: ModelCatalogSource): Promise<CatalogView> {
  const providers: CatalogView['providers'] = []
  const failures: CatalogView['failures'] = []
  for (const route of source.listProviders()) {
    try {
      const models = await source.listModels(route.id)
      providers.push({ provider: route.id, name: route.name, models: models.map(modelView) })
    } catch (error: unknown) {
      failures.push({ provider: route.id, message: error instanceof Error ? error.message : String(error) })
    }
  }
  return { providers, failures }
}

const MODELS_TOOL_DESCRIPTION =
  'List every model currently dispatchable in this deployment, live from the host catalog — use it '
  + 'whenever a plan assigns models to delegated subagents (e.g. parallel generation across different '
  + 'models) instead of assuming a fixed list. Each entry\'s { provider, id } maps 1:1 onto a '
  + 'subagent/delegation model override: pass BOTH together, because a bare model id rides the '
  + 'parent session\'s provider route and usually lands on the wrong one. inputModalities carries '
  + 'capability ("image" = vision-capable; absent = unknown, not negative). Routes that failed to '
  + 'enumerate appear under failures and must not be dispatched to this run.'

/**
 * Register the `rdd_models` catalog tool beside `rdd_explore`.
 * @param ctx - registrant context carrying the tools service.
 * @param source - the host catalog face (structural; production passes `ctx.llm`).
 * @param toolName - model-facing tool name (default `rdd_models`).
 */
export function registerModelsTool(ctx: Context, source: ModelCatalogSource, toolName = 'rdd_models'): void {
  ctx.tools.register(defineTool({
    name: toolName,
    description: MODELS_TOOL_DESCRIPTION,
    parameters: {},
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        required: ['providers', 'failures'],
        properties: {
          providers: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['provider', 'name', 'models'],
              properties: {
                provider: { type: 'string' },
                name: { type: 'string' },
                models: {
                  type: 'array',
                  items: {
                    type: 'object',
                    additionalProperties: false,
                    required: ['provider', 'id', 'name'],
                    properties: {
                      provider: { type: 'string' },
                      id: { type: 'string' },
                      name: { type: 'string' },
                      description: { type: 'string' },
                      inputModalities: { type: 'array', items: { type: 'string', enum: ['text', 'image'] } },
                    },
                  },
                },
              },
            },
          },
          failures: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['provider', 'message'],
              properties: {
                provider: { type: 'string' },
                message: { type: 'string' },
              },
            },
          },
        },
      },
      render: (_args, value) => [{
        type: 'text',
        text: renderCatalog(value as CatalogView),
      }],
    },
    // A pure read over the live catalog; concurrent calls are independent.
    isConcurrencySafe: () => true,
    async execute() {
      return await collectCatalog(source)
    },
    presentCall: args => ({ card: 'generic', title: 'List dispatchable models (live catalog)', kind: 'other', rawInput: args }),
  }))
}

/** Render the catalog as the model-facing text block. */
export function renderCatalog(view: CatalogView): string {
  if (view.providers.length === 0) {
    return 'No provider route is currently registered — no model can be selected for delegation this run; '
      + 'every subagent follows the parent session\'s model. (Routes that failed to enumerate: '
      + `${view.failures.length}; this is a deployment state, not a query error.)`
  }
  const groups = view.providers.map(group => {
    const models = group.models.map(model =>
      `- ${model.provider} / ${model.id} (${model.name}${model.inputModalities === undefined ? '' : `, ${model.inputModalities.join('+')}`})`)
    return `${group.provider} (${group.name}):\n${models.join('\n')}`
  })
  const failed = view.failures.length === 0
    ? ''
    : `\nFailed to enumerate (do not dispatch to these this run): ${view.failures.map(failure => failure.provider).join(', ')}.`
  return `Dispatchable models, live from the host catalog (pass { provider, id } together as the delegation override):\n${groups.join('\n')}${failed}`
}
