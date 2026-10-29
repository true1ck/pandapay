#!/usr/bin/env python3
"""Build a reviewed V2 workflow; optionally sign with Apple's shortcuts CLI.

No message content or personal auth metadata is included. Original export is
never modified. The Messages property bindings match the user's decoded export.
"""
import argparse
import copy
import plistlib
import subprocess
import uuid
from pathlib import Path

NAME = 'PANDAPAY SELECTED RANGE V2'
BUNDLE = 'app.pandapay.iosimportprobe'

def uid(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, 'pandapay/history-range-v2/' + name)).upper()

def token(value):
    return {'Value': value, 'WFSerializationType': 'WFTextTokenAttachment'}

def output(name, label):
    return token({'Type': 'ActionOutput', 'OutputUUID': uid(name), 'OutputName': label})

INPUT = token({'Type': 'ExtensionInput'})

def action(identifier, key, **params):
    return {'WFWorkflowActionIdentifier': identifier,
            'WFWorkflowActionParameters': {'UUID': uid(key), **params}}

def intent(name, key, **params):
    return action(BUNDLE + '.' + name, key, AppIntentDescriptor={
        'AppIntentIdentifier': name, 'BundleIdentifier': BUNDLE,
        'Name': 'PandaPay History Probe', 'TeamIdentifier': 'NS2853H32R',
    }, **params)

def repeat_property(name):
    info = {'WFLinkEntityContentPropertyUserInfoPropertyIdentifier': name}
    if name == 'author': info['WFLinkEntityContentPropertyUserInfoIsContactHandleKey'] = True
    if name == 'body': info['WFLinkEntityContentPropertyUserInfoTextContentSpotlightAttributeKey'] = True
    return token({'Type': 'Variable', 'VariableName': 'Repeat Item', 'Aggrandizements': [{
        'Type': 'WFPropertyVariableAggrandizement', 'PropertyName': name, 'PropertyUserInfo': info,
    }]})

def workflow():
    actions = [
        intent('PrepareDeviceHistoryRangeIntent', 'start', request=INPUT),
        intent('DeviceHistoryRangeEndIntent', 'end', request=INPUT),
        action('com.apple.MobileSMS.MessageEntity', 'find', AppIntentDescriptor={
            'ActionRequiresAppInstallation': True, 'AppIntentIdentifier': 'MessageEntity',
            'BundleIdentifier': 'com.apple.MobileSMS', 'Name': 'Messages', 'TeamIdentifier': '0000000000',
        }, WFContentItemFilter={'Value': {
            'WFActionParameterFilterPrefix': 1, 'WFContentPredicateBoundedDate': False,
            'WFActionParameterFilterTemplates': [{
                'Operator': 1003, 'Property': 'date', 'Removable': True,
                'Values': {'Date': output('start', 'Search Start'), 'AnotherDate': output('end', 'Range End')},
            }],
        }, 'WFSerializationType': 'WFContentPredicateTableTemplate'},
            WFContentItemLimitEnabled=False, WFContentItemSortOrder='Oldest First', WFContentItemSortProperty='date'),
        action('is.workflow.actions.count', 'count', Input=output('find', 'Message'), WFCountType='Items'),
        action('is.workflow.actions.repeat.each', 'repeat', WFInput=output('find', 'Message'), WFControlFlowMode=0, GroupingIdentifier=uid('loop')),
        intent('CaptureDeviceHistoryRangeMessageIntent', 'capture', request=INPUT,
               body=repeat_property('body'), senderPerson=repeat_property('author'), receivedAt=repeat_property('date')),
        action('is.workflow.actions.repeat.each', 'endrepeat', WFControlFlowMode=2, GroupingIdentifier=uid('loop')),
        intent('FinishDeviceHistoryRangeIntent', 'finish', request=INPUT, found=output('count', 'Count')),
        action('is.workflow.actions.output', 'output', WFOutput={'Value': {'string': '\ufffc', 'attachmentsByRange': {'{0, 1}': output('finish', 'Range Import Report')['Value']}}, 'WFSerializationType': 'WFTextTokenString'}),
    ]
    return {
        'WFWorkflowName': NAME, 'WFWorkflowActions': copy.deepcopy(actions),
        'WFWorkflowClientVersion': '5110.0.8', 'WFWorkflowMinimumClientVersion': 900,
        'WFWorkflowMinimumClientVersionString': '900',
        'WFWorkflowIcon': {'WFWorkflowIconGlyphNumber': 61440, 'WFWorkflowIconStartColor': 946986751},
        'WFWorkflowHasShortcutInputVariables': True, 'WFWorkflowHasOutputFallback': False,
        'WFWorkflowImportQuestions': [], 'WFQuickActionSurfaces': [],
        'WFWorkflowInputContentItemClasses': ['WFStringContentItem'],
        'WFWorkflowOutputContentItemClasses': ['WFStringContentItem'],
        'WFWorkflowTypes': ['WFWorkflowTypeShowInSearch'],
    }

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sign', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    source = args.output / (NAME + '.wflow')
    source.write_bytes(plistlib.dumps(workflow(), fmt=plistlib.FMT_XML, sort_keys=False))
    print(source)
    if args.sign:
        signed = args.output / (NAME + '.shortcut')
        subprocess.run(['shortcuts', 'sign', '--mode', 'anyone', '--input', str(source), '--output', str(signed)], check=True)
        print(signed)

if __name__ == '__main__':
    main()
