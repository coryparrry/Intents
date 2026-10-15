#!/usr/bin/env python3
"""Checks actual app workflow algorithms and source-owned rejection cases."""
import copy,json,subprocess,sys,uuid
binary=sys.argv[1];infer='--infer' in sys.argv[2:];checks=0

def check(value,detail=''):
 global checks
 assert value,detail
 checks+=1

def invoke(value):
 process=subprocess.run([binary],input=json.dumps(value),text=True,capture_output=True,timeout=180,check=True)
 check(len(process.stdout.strip().splitlines())==1,process.stdout[:200])
 return json.loads(process.stdout)

def uid():return str(uuid.uuid4())
def base():
 suite=invoke({'operation':'suite-defaults'});suite.update(instructions='Follow the prompt exactly.',scoringMode='exactMatch',criteria='',repetitions=2)
 suite['modelConfiguration'].update(samplingMode='greedy',maximumResponseTokens=128)
 suite['cases']=[{'id':uid(),'name':'workflow','prompt':'Reply with exactly READY','expected':'READY'}]
 suite['releasePolicy']['requireApprovedBaseline']=True;suite['releasePolicy']['criticalCaseIDs']=[suite['cases'][0]['id']]
 return suite

suite=base();candidate='Follow every user instruction precisely, including exact reply constraints.'
experiment=invoke({'operation':'create-experiment','suite':suite,'candidateInstructions':candidate,'name':'Frozen paired experiment'})
check(experiment['current']['instructions']==suite['instructions'])
check(experiment['candidate']['instructions']==candidate)
currentID=experiment['current']['id'];candidateID=experiment['candidate']['id']
check(experiment['executionOrder']==[currentID,candidateID,candidateID,currentID])
check(len(experiment['casesDigest'])==64 and len(experiment['scoringDigest'])==64 and len(experiment['judgeDigest'])==64)
check(experiment['current']['suiteRevision']!=experiment['candidate']['suiteRevision'])
changed=copy.deepcopy(suite);changed['instructions']='Changed after freeze.'
rejected=invoke({'operation':'run-experiment','suite':changed,'experiment':experiment})
check(rejected['status']=='failed' and rejected['error']['kind']=='invalidInput')
oversized=copy.deepcopy(suite);oversized['repetitions']=9223372036854775807
check(invoke({'operation':'run-experiment','suite':oversized,'experiment':experiment})['status']=='failed')
missing=invoke({'operation':'release-check','projectID':uid(),'suite':suite})
check(missing['report']['outcome']==20 and 'No completed run' in missing['report']['summary'])
project=invoke({'operation':'project-release-check','projectID':uid(),'suites':[{'suiteID':suite['id'],'suiteName':suite['name'],'required':True,'report':missing['report']}]})
check(project['report']['outcome']==20)
check('Required suites' in project['markdown'] and 'Intent Lab' not in project['markdown'])

if infer:
 requestedCurrent=uid();requestedCandidate=uid()
 outcome=invoke({'operation':'run-experiment','suite':suite,'experiment':experiment,'currentRunID':requestedCurrent,'candidateRunID':requestedCandidate})
 check('current' in outcome and 'candidate' in outcome,outcome.get('error'))
 current=outcome['current'];candidateRun=outcome['candidate']
 check(uuid.UUID(current['id'])==uuid.UUID(requestedCurrent))
 check(uuid.UUID(candidateRun['id'])==uuid.UUID(requestedCandidate))
 check(outcome['experiment']['runIDs']==[current['id'],candidateRun['id']])
 check(len(current['results'])==2 and len(candidateRun['results'])==2)
 check([result['repetition'] for result in current['results']]==[1,2])
 check(all(result['status']=='passed' and result['response'].strip()=='READY' for result in current['results']+candidateRun['results']))
 check(current['instructions']==suite['instructions'] and candidateRun['instructions']==candidate)
 check(current['suiteDefinition']['instructions']==suite['instructions'])
 check(outcome['summary']['suggestedDecision']=='collectMoreEvidence')
 check(outcome['summary']['distinctCaseCoverage']==1 and outcome['summary']['repetitionsPerCase']==2)
 check(invoke({'operation':'summarize-experiment','current':current,'candidate':candidateRun})==outcome['summary'])
 compare=invoke({'operation':'compare-runs','current':candidateRun,'baseline':current})
 check(compare['compatibility']=='compatible',compare)
 check(compare['unchangedCaseCount']==1 and compare['regressedCaseCount']==0)
 analysis=invoke({'operation':'analyze-run','run':current})
 check(analysis['completedSampleCount']==2 and analysis['missingSampleCount']==0)
 check(analysis['cases'][0]['repetitionVariation']=='consistentlyPassed')
 approval=invoke({'operation':'approve-baseline','suite':suite,'run':current,'note':'Reviewed actual local paired run.'})
 check(approval['runID']==current['id'] and approval['suiteRevision']==current['suiteRevision'])
 check(approval['scoringContract']['scoringMode']=='exactMatch')
 release={'operation':'release-check','projectID':uid(),'suite':suite,'run':current,'baseline':current,'approvedBaseline':approval}
 report=invoke(release);check(report['report']['outcome']==0,report)
 regression=copy.deepcopy(current);regression['results'][0]['status']='failed';regression['results'][0]['response']='BAD'
 failing=invoke({**release,'run':regression})
 check(failing['report']['outcome']==10,failing)
 check(any('Critical case' in failure for failure in failing['report']['failures']))
 duplicate=copy.deepcopy(current);duplicate['results'][1]=copy.deepcopy(duplicate['results'][0])
 check(invoke({**release,'run':duplicate})['report']['outcome']==20)
 cancelled=copy.deepcopy(current);cancelled['cancelled']=True
 check(invoke({'operation':'approve-baseline','suite':suite,'run':cancelled})['status']=='failed')
 incompatible=copy.deepcopy(candidateRun);incompatible['scoringMode']='review'
 check(invoke({'operation':'compare-runs','current':incompatible,'baseline':current})['compatibility']=='incompatible')
 judgeSuite=base();judgeSuite.update(scoringMode='modelJudge',criteria='The response supplies the requested word without unrelated text.',repetitions=1)
 judged=invoke({'operation':'evaluate','suite':judgeSuite});check(judged['status']=='completed',judged.get('error'))
 run=judged['appRun'];assessment=run['selectedAssessmentID'];sample=run['results'][0]
 selected=invoke({'operation':'select-assessment','run':run,'assessmentID':assessment})
 check(selected['results']==run['results'] and selected['selectedAssessmentID']==assessment)
 correction=invoke({'operation':'correct-judgment','suite':judgeSuite,'run':run,'sampleID':sample['id'],'correctedStatus':'failed','correctedScore':1,'reason':'Human review fixture: retained original judgment.','collectAsJudgeCheck':True})
 check(correction['run']==run)
 check(correction['correction']['originalStatus']==sample['status'] and correction['correction']['originalScore']==sample['score'])
 check(correction['correction']['correctedStatus']=='failed' and correction['correction']['correctedScore']==1)
 check(correction['reviewedJudgeExample']['scoringContract']==run['assessments'][0]['scoringContract'])
 approved=invoke({'operation':'approve-baseline','suite':judgeSuite,'run':run,'assessmentID':assessment})
 check(approved['assessmentID']==assessment and approved['scoringContract']['rubricCriteria']==[judgeSuite['criteria']])
 check(invoke({'operation':'select-assessment','run':run,'assessmentID':uid()})['status']=='failed')
 check(invoke({'operation':'correct-judgment','suite':judgeSuite,'run':run,'sampleID':sample['id'],'correctedStatus':'failed','reason':' '})['status']=='failed')
print(f'Actual app workflows: {checks} assertions passed; inference={infer}')
