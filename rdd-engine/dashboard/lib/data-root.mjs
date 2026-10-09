// Runtime data-root state — one holder per server instance (CTO decision 7).
//
// The dashboard used to freeze the resolved context in a startServer closure;
// the project switcher turns that into a swappable "current root". A factory
// (not a module singleton) keeps the two same-process test servers isolated,
// and switching is a plain reference swap: a request reads getCurrent() once,
// so every domain in that request reads the same root — no mixed state, and
// requests already in flight finish on the root they captured.
import { validateProjectRoot } from './paths.mjs'

/**
 * Create an isolated current-root holder.
 * @param {{projectRoot: string, rddRoot: string, source?: string}} initialContext
 * @returns {{getCurrent: () => {projectRoot: string, rddRoot: string, source: string}, switchTo: (candidate: string) => object}}
 */
export function createDataRootHolder(initialContext) {
  let current = { source: 'startup', ...initialContext }
  return {
    getCurrent: () => current,
    switchTo(candidate) {
      const verdict = validateProjectRoot(candidate)
      if (verdict.ok !== true) return verdict
      const previousRoot = current.projectRoot
      current = { projectRoot: verdict.projectRoot, rddRoot: verdict.rddRoot, source: 'runtime-switch' }
      return { ok: true, projectRoot: verdict.projectRoot, previousRoot }
    },
  }
}
