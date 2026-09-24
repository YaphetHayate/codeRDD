# fixture code-metrics bridge-n7r1 (base side) - deferred stitching
# flattened: deepest chain foreach -> foreach -> if (3 levels).
function Invoke-Promulgate {
    # base side: deferred stitching flattened, deepest chain 3 levels
    foreach ($task in $tasks) {
        foreach ($nodeId in $ids) {
            if ($nodeId -in $edges) {
                $stitched = $nodeId
            }
        }
    }
}
