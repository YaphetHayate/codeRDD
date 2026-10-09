// Mirror-test boot helper (goal-tree ops-config-panel n4).
//
// Boots the dashboard quietly on the throwaway workspace named by the
// QA_MIRROR_ROOT env var (port QA_MIRROR_PORT, default 8831). Used only by
// tests/test-config-engine-mirror.ps1, which starts this file as a detached
// node process and stops it when done.
import { join } from 'node:path'

import { startServer } from '../dashboard/server.mjs'

const root = process.env.QA_MIRROR_ROOT
const port = Number(process.env.QA_MIRROR_PORT ?? '8831')
startServer({ context: { projectRoot: root, rddRoot: join(root, '.rdd') }, port, quiet: true })
