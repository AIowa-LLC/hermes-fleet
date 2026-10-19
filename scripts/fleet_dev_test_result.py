#!/usr/bin/env python3
"""Verify all eight Dev isolation cases passed once; preserve existing parser."""
import json
import sys
from c1_xcresult_parse import parse

EXPECTED = {
    'testHostHasOnlyDevelopmentIdentity()',
    'testProductionIdentityRemainsStable()',
    'testInconsistentDevelopmentMetadataFailsClosed()',
    'testDevCredentialSaveAndDeletePreserveProductionItem()',
    'testFreshDevInstallPurgePreservesAllProductionServices()',
    'testEveryStoreUsesDevNamespaceAndPrivateDefaultAccessGroup()',
    'testShortcutRoundTripRejectsProductionScheme()',
    'testCacheIdentityAndDefaultsDomainSeparateFromProduction()',
}

def verify(summary, tests):
    values = parse(summary, tests, 'FleetDevIsolationTests', set(), EXPECTED)
    if values != (8, 0, 1, 1, 0) or summary.get('skippedTests') != 0:
        raise ValueError('Dev isolation selection/result incomplete, skipped, failed or recovered: ' + str(values))
    # Existing parser's clean-attempt helper is stricter than aggregate pass.
    from c1_xcresult_parse import single_clean_attempt, walk
    nodes = [n for n in walk(tests) if n.get('nodeType') == 'Test Case' and 'FleetDevIsolationTests/' in str(n.get('nodeIdentifier', ''))]
    if len(nodes) != 8 or not all(single_clean_attempt(n) for n in nodes):
        raise ValueError('Dev isolation cases must each have one clean attempt')
    print('Fleet Dev isolation: 8 cases passed once, zero failures/skips/recovered attempts')

if __name__ == '__main__':
    try:
        verify(json.load(open(sys.argv[1])), json.load(open(sys.argv[2])))
    except (ValueError, OSError, KeyError, TypeError) as e:
        raise SystemExit('FLEET-DEV-FAIL: ' + str(e))
