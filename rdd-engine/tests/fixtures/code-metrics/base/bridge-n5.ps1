# fixture code-metrics bridge-n5 (base side) - flattened nesting baselines:
# Invoke-BridgeSettle depth 3, Resolve-RollbackGraftParent depth 2.
function Invoke-BridgeSettle {
    # base side: settle tail flattened, deepest chain if -> if -> if
    if ($phase) {
        if ($nodeId) {
            if ($stages) {
                $settled = $stages
            }
        }
    }
}
function Resolve-RollbackGraftParent {
    # base side: guard flattened, deepest chain foreach -> if
    foreach ($node in $nodes) {
        if ($node.parent) {
            $anchor = $node
        }
    }
}
