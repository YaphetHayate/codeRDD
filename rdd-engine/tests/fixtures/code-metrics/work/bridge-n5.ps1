# fixture code-metrics bridge-n5 (work side) - n5-round chain shapes:
# 5/5/4 levels; under the 5-depth caliber all three are zero-FP contrast.
function Invoke-BridgeSettle {
    # work side: 5-level chain if x4 -> foreach (n5-round replica #1)
    if ($phase) {
        if ($nodeId) {
            if ($stages) {
                if ($pending) {
                    foreach ($entry in $stages) {
                        $settled = $entry
                    }
                }
            }
        }
    }
}
function Resolve-RollbackGraftParent {
    # work side: 5-level chain foreach -> if x4 (n5-round replica #2)
    foreach ($node in $nodes) {
        if ($node.parent) {
            if ($node.id) {
                if ($node.status) {
                    if ($node.blocked) {
                        $anchor = $node
                    }
                }
            }
        }
    }
}
function Format-StageChain {
    # work side: new function, 4-level chain foreach -> if(else) -> foreach -> if
    # (n5-round replica #3; exercises the (else) clause annotation)
    foreach ($stage in $stages) {
        if ($stage.role) {
            $shown = $stage
        } else {
            foreach ($role in $stage.roles) {
                if ($role) {
                    $shown = $role
                }
            }
        }
    }
}
