# fixture code-metrics nest-deep (work side only, untracked new file) -
# synthetic >=6-level nesting sample: no historical instance exists, the
# acceptance baseline requires the tool to catch it as a new violation.
function Invoke-DeepNest {
    # synthetic 6-level chain if -> foreach -> if -> foreach -> while -> if
    if ($a) {
        foreach ($b in $items) {
            if ($b) {
                foreach ($c in $b.children) {
                    while ($c.next) {
                        if ($c.done) {
                            $handled = $c
                        }
                    }
                }
            }
        }
    }
}
function Invoke-CleanHelper {
    # control sample: small and shallow, must stay clean
    $loaded = $items
    $kept = @()
    foreach ($item in $loaded) {
        if ($item) { $kept += $item }
    }
    return $kept
}
