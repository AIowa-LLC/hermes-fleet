#!/usr/bin/env python3
"""Reject incomplete, stale, foreign or tampered UI evidence before reuse."""
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import c1_ui_receipt as receipt
from c1_ui_case_inventory import cases
from c1_ui_partition import partition, runtime_weights

ROOT = Path(__file__).resolve().parent.parent


class ReceiptContracts(unittest.TestCase):
    def setUp(self):
        self.context = {'repository':'fixture/fleet', 'repository_id':100, 'run_id':200,
                        'source_head':'a'*40, 'tree':'b'*40, 'base':'c'*40,
                        'environment':{'xcode':'fixture', 'runtime':'fixture', 'dependency_locks':{'fixture':'d'*64}},
                        'requested':list(runtime_weights(ROOT/'scripts/c1_ui_matrix.sh'))}
        buckets = partition(self.context['requested'], runtime_weights(ROOT/'scripts/c1_ui_matrix.sh'), 12)
        self.receipts = []
        for i, selected in enumerate(buckets, 1):
            item = dict(self.context, schema=1, shard=i, shards=12, event='pull_request', run_attempt=1,
                        validation_changed=False, clean_checkout=True, clean_attempts=True, selected=selected,
                        cases={name:{method:['Skipped'] if name=='U3TabNavigation' and method=='testIPadLandscapePreservesRootNavigation()' else ['Passed']
                                     for method in cases(ROOT,name)} for name in selected})
            self.receipts.append(item)

    def test_full_inventory_is_accepted_with_only_reviewed_orientation_skip(self):
        receipt.validate_receipts(self.receipts, self.context)
        self.assertEqual(sum(len(r['cases']) for r in self.receipts), len(self.context['requested']))
        records = {name: methods for item in self.receipts for name, methods in item['cases'].items()}
        self.assertIn('testGroupConversationOpensAtLatestWithDeepHistory()', records['FOS8Accessibility'])
        self.assertIn('testDrawerPinnedConversationRowIsTappableAcrossItsWholeWidth()', records['U3TabNavigation'])

    def test_missing_and_duplicate_partitions_are_rejected(self):
        for items in (self.receipts[:-1], self.receipts[:-1]+[self.receipts[0]]):
            with self.assertRaises(ValueError):
                receipt.validate_receipts(items, self.context)

    def test_provenance_mismatch_runs_fresh(self):
        values = {'repository':'foreign/fleet','repository_id':999,'run_id':201,'source_head':'e'*40,
                  'tree':'f'*40,'base':'0'*40,'environment':{},'requested':[], 'schema':2,'shards':5,
                  'event':'push','run_attempt':2,'validation_changed':True,'clean_checkout':False,'clean_attempts':False}
        for key, value in values.items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                items=deepcopy(self.receipts);items[0][key]=value
                receipt.validate_receipts(items,self.context)

    def test_changed_compiler_sdk_runtime_runner_or_locked_dependencies_runs_fresh(self):
        for key in ('xcode','swift','sdk_version','sdk_build','macos','macos_build','architecture',
                    'runtime','runtime_build','device_type','runner_image_version','dependency_locks','build_policy'):
            with self.subTest(key=key), self.assertRaises(ValueError):
                items=deepcopy(self.receipts);items[0]['environment'][key]='different'
                receipt.validate_receipts(items,self.context)

    def test_wrong_selection_or_class_inventory_is_rejected(self):
        for key,value in [('selected',[]),('cases',{})]:
            with self.assertRaises(ValueError):
                items=deepcopy(self.receipts);items[0][key]=value
                receipt.validate_receipts(items,self.context)

    def test_missing_extra_failed_skipped_retried_unknown_cases_are_rejected(self):
        for action in ('missing','extra','failed','skipped','retried','empty','unknown'):
            with self.subTest(action=action), self.assertRaises(ValueError):
                items=deepcopy(self.receipts)
                records=next(iter(items[0]['cases'].values()));key=next(iter(records))
                if action=='missing': del records[key]
                elif action=='extra': records['testUnexpected()']=['Passed']
                else: records[key]={'failed':['Failed'],'skipped':['Skipped'],'retried':['Failed','Passed'],
                                    'empty':[],'unknown':['Mystery']}[action]
                receipt.validate_receipts(items,self.context)

    def test_empty_selection_still_requires_twelve_complete_receipts(self):
        context=dict(self.context,requested=[])
        items=[dict(r,requested=[],selected=[],cases={}) for r in self.receipts]
        receipt.validate_receipts(items,context)
        with self.assertRaises(ValueError): receipt.validate_receipts(items[:-1],context)

    def test_complete_native_reuse_checks_live_metadata_artifacts_and_checkout(self):
        import os
        source_checkout='e'*40
        run={'id':200,'event':'pull_request','path':'.github/workflows/ci.yml','head_sha':'a'*40,
             'head_repository':{'id':100},'status':'completed','conclusion':'success','run_attempt':1,
             'created_at':datetime.now(timezone.utc).isoformat()}
        jobs=[{'name':name,'status':'completed','conclusion':'success'} for name in
              ['CI Gate',*[f'UI preflight {i}/12 (changed area)' for i in range(1,13)]]]
        checks=[{'name':'CI Gate','app':{'id':15368},'head_sha':'a'*40,'status':'completed','conclusion':'success',
                 'details_url':'https://github.com/fixture/fleet/actions/runs/200/job/300'}]
        artifacts=[];archives={}
        for item in self.receipts:
            shard=item['shard'];out=io.BytesIO()
            with zipfile.ZipFile(out,'w') as z:
                z.writestr(f'ui-receipt-{shard}.json',json.dumps(dict(item,checkout=source_checkout)))
            archives[shard]=out.getvalue()
            artifacts.append({'id':shard,'name':f'ui-receipt-{shard}-attempt-1','expired':False,'size_in_bytes':len(archives[shard]),
                              'digest':'sha256:'+hashlib.sha256(archives[shard]).hexdigest(),
                              'workflow_run':{'id':200,'head_sha':'a'*40,'repository_id':100,'head_repository_id':100}})
        def github(repository,path,binary=False):
            self.assertEqual(repository,'fixture/fleet')
            if path=='pulls/17': return {'state':'open','draft':False,'base':{'ref':'main'},'head':{'sha':'a'*40,'repo':{'id':100}}}
            if path.startswith('actions/workflows/'): return {'workflow_runs':[run]}
            if '/jobs?' in path: return {'jobs':jobs}
            if '/check-runs?' in path: return {'check_runs':checks}
            if '/artifacts?' in path: return {'artifacts':artifacts}
            if path.startswith('actions/artifacts/'): return archives[int(path.split('/')[2])]
            if path.startswith('git/commits/'): return {'tree':{'sha':'b'*40},'parents':[{'sha':'c'*40},{'sha':'a'*40}]}
            raise AssertionError(path)
        def git(*args):
            if args[0]=='status': return ''
            if args[0]=='show': return 'c'*40
            if args==('rev-parse','HEAD^{tree}'): return 'b'*40
            if args==('rev-parse','HEAD'): return 'f'*40
            if args==('rev-parse','fixture-base'): return 'c'*40
            raise AssertionError(args)
        with tempfile.TemporaryDirectory() as directory:
            event=Path(directory)/'event.json';event.write_text(json.dumps({'merge_group':{'head_ref':'refs/heads/gh-readonly-queue/main/pr-17-'+'c'*40}}))
            env={'GITHUB_EVENT_NAME':'merge_group','GITHUB_EVENT_PATH':str(event),'GITHUB_REPOSITORY':'fixture/fleet','GITHUB_REPOSITORY_ID':'100','RUNNER_TEMP':directory}
            with patch.dict(os.environ,env),patch.object(receipt.subprocess,'run',return_value=type('Result',(),{'returncode':0})()),patch.object(receipt,'api',side_effect=github),patch.object(receipt,'git',side_effect=git),patch.object(receipt,'environment',return_value=self.context['environment']),patch.object(receipt,'validation_changed',return_value=False):
                proof=receipt.reuse('fixture-base',1,self.context['requested'])
        self.assertEqual(proof['mode'],'verified-source-reuse')
        self.assertEqual(proof['candidate'],'f'*40)
        self.assertEqual(len(proof['artifacts']),12)
        self.assertEqual(proof['selected'],self.receipts[0]['selected'])


class GitHubTrustContracts(unittest.TestCase):
    def setUp(self):
        self.run={'id':200,'event':'pull_request','path':'.github/workflows/ci.yml','head_sha':'a'*40,
                  'head_repository':{'id':100},'status':'completed','conclusion':'success','run_attempt':1,
                  'created_at':datetime.now(timezone.utc).isoformat()}
        self.jobs=[{'name':name,'status':'completed','conclusion':'success'} for name in
                   ['CI Gate',*[f'UI preflight {i}/12 (changed area)' for i in range(1,13)]]]
        self.checks=[{'name':'CI Gate','app':{'id':15368},'head_sha':'a'*40,'status':'completed','conclusion':'success',
                      'details_url':'https://github.com/fixture/fleet/actions/runs/200/job/300'}]

    def verify(self):
        receipt.validate_run(self.run,self.jobs,self.checks,'fixture/fleet',100,'a'*40)

    def test_actual_successful_actions_gate_and_complete_jobs_are_required(self): self.verify()

    def test_foreign_fork_stale_failed_expired_and_rerun_sources_are_rejected(self):
        values={'event':'push','path':'.github/workflows/foreign.yml','head_sha':'b'*40,'head_repository':{'id':999},
                'status':'in_progress','conclusion':'failure','run_attempt':2,
                'created_at':(datetime.now(timezone.utc)-timedelta(days=2)).isoformat()}
        original=deepcopy(self.run)
        for key,value in values.items():
            with self.subTest(key=key),self.assertRaises(ValueError):
                self.run=deepcopy(original);self.run[key]=value;self.verify()

    def test_missing_duplicate_cancelled_skipped_failed_jobs_are_rejected(self):
        original=deepcopy(self.jobs)
        for action in ('missing','duplicate','cancelled','skipped','failure'):
            with self.subTest(action=action),self.assertRaises(ValueError):
                self.jobs=deepcopy(original)
                if action=='missing': self.jobs.pop()
                elif action=='duplicate': self.jobs.append(self.jobs[-1])
                else: self.jobs[-1]['conclusion']=action
                self.verify()

    def test_user_posted_wrong_app_wrong_run_and_stale_gate_are_rejected(self):
        values={'app':{'id':999},'details_url':'https://github.com/fixture/fleet/actions/runs/201/job/300',
                'head_sha':'b'*40,'conclusion':'failure','status':'in_progress'}
        original=deepcopy(self.checks[0])
        for key,value in values.items():
            with self.subTest(key=key),self.assertRaises(ValueError):
                self.checks=[dict(original,**{key:value})];self.verify()


class ArtifactContracts(unittest.TestCase):
    def archive(self,name='ui-receipt-1.json',content=None):
        out=io.BytesIO()
        with zipfile.ZipFile(out,'w') as z: z.writestr(name,json.dumps(content or {'schema':1}))
        return out.getvalue()

    def setUp(self):
        self.data=self.archive()
        self.artifact={'name':'ui-receipt-1-attempt-1','expired':False,
                       'digest':'sha256:'+hashlib.sha256(self.data).hexdigest(),
                       'workflow_run':{'id':200,'head_sha':'a'*40,'repository_id':100,'head_repository_id':100}}

    def test_digest_bound_receipt_is_read_without_extracting_paths(self):
        self.assertEqual(receipt.artifact_receipt(self.artifact,self.data,100,200,'a'*40,1),{'schema':1})

    def test_tampered_missing_digest_foreign_expired_artifacts_are_rejected(self):
        for key,value in [('name','foreign'),('expired',True),('digest','sha256:wrong'),('workflow_run',{})]:
            with self.subTest(key=key),self.assertRaises(ValueError):
                receipt.artifact_receipt(dict(self.artifact,**{key:value}),self.data,100,200,'a'*40,1)
        with self.assertRaises(ValueError): receipt.artifact_receipt(self.artifact,self.data+b'tamper',100,200,'a'*40,1)

    def test_zip_path_traversal_or_extra_files_are_rejected_without_extraction(self):
        data=self.archive('../../ui-receipt-1.json')
        artifact=dict(self.artifact,digest='sha256:'+hashlib.sha256(data).hexdigest())
        with self.assertRaises(ValueError): receipt.artifact_receipt(artifact,data,100,200,'a'*40,1)


class CaseInventoryContracts(unittest.TestCase):
    def test_async_throwing_methods_are_exact_and_helpers_are_excluded(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'HermesFleetAppUITests').mkdir()
            file=root/'HermesFleetAppUITests/ExampleUITests.swift'
            file.write_text("final class ExampleUITests {\n func testOne() async throws {}\n func testTwo() {}\n func helper() {}\n}\n")
            self.assertEqual(cases(root,'Example'),['testOne()','testTwo()'])
            file.write_text(file.read_text().replace('func helper()', 'func testOne()'))
            with self.assertRaises(ValueError): cases(root,'Example')
            with self.assertRaises(ValueError): cases(root,'../Example')


class FreshFallbackContracts(unittest.TestCase):
    def test_build_definition_and_validation_changes_disable_reuse(self):
        for path in ('project.yml','HermesFleetApp.xcodeproj/project.pbxproj',
                     'Packages/FleetCore/Package.swift','Packages/FleetUI/Package.resolved',
                     'scripts/c1_ui_matrix.sh','.github/workflows/ci.yml',
                     'HermesFleetAppUITests/ExampleUITests.swift',
                     'Packages/FleetCore/Tests/FleetCoreTests/Example.swift'):
            with self.subTest(path=path),patch.object(receipt,'git',return_value=path):
                self.assertTrue(receipt.validation_changed('base'))
        with patch.object(receipt,'git',return_value='HermesFleetApp/FleetServiceGraph.swift'):
            self.assertFalse(receipt.validation_changed('base'))

    def test_missing_runner_image_metadata_cannot_claim_environment_match(self):
        with patch.dict('os.environ',{'GITHUB_ACTIONS':'true','ImageOS':'','ImageVersion':''}),patch.object(receipt,'command') as command:
            with self.assertRaises(receipt.ReceiptRejected): receipt.environment()
            command.assert_not_called()

    def test_validation_change_disables_reuse_before_network(self):
        with patch.dict('os.environ',{'GITHUB_EVENT_NAME':'merge_group'}),patch.object(receipt,'validation_changed',return_value=True),patch.object(receipt,'api') as network:
            with self.assertRaises(ValueError): receipt.reuse('fixture',1,['Splash'])
            network.assert_not_called()

    def test_pr_local_and_fork_workflows_do_not_reuse(self):
        for event in ('pull_request','push','workflow_dispatch',''):
            with patch.dict('os.environ',{'GITHUB_EVENT_NAME':event}),patch.object(receipt,'api') as network:
                with self.assertRaises(ValueError): receipt.reuse('fixture',1,['Splash'])
                network.assert_not_called()


if __name__=='__main__': unittest.main(verbosity=2)
