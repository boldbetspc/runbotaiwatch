#!/usr/bin/env python3
"""
Generate a proper Xcode project structure for RunbotAIWatch
"""
import os
import uuid
import json
from pathlib import Path

def generate_uuid():
    """Generate a UUID suitable for Xcode"""
    return uuid.uuid4().hex[:24].upper()

def create_pbxproj():
    """Create a valid project.pbxproj file"""
    
    # File UUIDs
    uuids = {
        'project': generate_uuid(),
        'pbx_group_main': generate_uuid(),
        'pbx_group_views': generate_uuid(),
        'pbx_group_models': generate_uuid(),
        'pbx_group_assets': generate_uuid(),
        'pbx_group_watch': generate_uuid(),
        'pbx_target_ios': generate_uuid(),
        'pbx_target_watch': generate_uuid(),
        'pbx_target_watch_kit': generate_uuid(),
        'pbx_config_debug': generate_uuid(),
        'pbx_config_release': generate_uuid(),
        'pbx_build_phase_sources': generate_uuid(),
        'pbx_build_phase_resources': generate_uuid(),
        'pbx_build_phase_frameworks': generate_uuid(),
    }
    
    # Source files to include
    source_files = {
        'RunbotAIWatchApp.swift': 'sourcecode.swift',
        'Views/ContentView.swift': 'sourcecode.swift',
        'Views/AuthenticationView.swift': 'sourcecode.swift',
        'Views/MainRunbotView.swift': 'sourcecode.swift',
        'Views/RunningView.swift': 'sourcecode.swift',
        'Views/SettingsView.swift': 'sourcecode.swift',
        'Models/AuthenticationManager.swift': 'sourcecode.swift',
        'Models/RunTracker.swift': 'sourcecode.swift',
        'Models/VoiceManager.swift': 'sourcecode.swift',
        'Models/AICoachManager.swift': 'sourcecode.swift',
        'Models/SupabaseManager.swift': 'sourcecode.swift',
        'Models/Mem0Manager.swift': 'sourcecode.swift',
        'Models/UserPreferences.swift': 'sourcecode.swift',
        'Models/RunDataModels.swift': 'sourcecode.swift',
        'Models/HealthManager.swift': 'sourcecode.swift',
        'Models/HeartZoneCalculator.swift': 'sourcecode.swift',
        'Models/WatchConnectivityManager.swift': 'sourcecode.swift',
        'Info.plist': 'text.plist.xml',
        'Config.plist': 'text.plist.xml',
    }
    
    pbxproj = """// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 60;
	objects = {

/* Begin PBXFileReference section */
"""
    
    # Add file references
    file_refs = {}
    for filename, filetype in source_files.items():
        uuid = generate_uuid()
        file_refs[filename] = uuid
        pbxproj += f"\t\t{uuid} /* {filename} */ = {{isa = PBXFileReference; lastKnownFileType = {filetype}; path = {filename}; sourceTree = \"<group>\"; }};\n"
    
    pbxproj += """/* End PBXFileReference section */

/* Begin PBXGroup section */
"""
    
    # Main group
    pbxproj += f"""\t\t{uuids['pbx_group_main']} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{file_refs['RunbotAIWatchApp.swift']},
\t\t\t\t{uuids['pbx_group_views']},
\t\t\t\t{uuids['pbx_group_models']},
\t\t\t\t{file_refs['Info.plist']},
\t\t\t\t{file_refs['Config.plist']},
\t\t\t);
\t\t\tpath = RunbotAIWatch;
\t\t\tsourceTree = \"<group>\";
\t\t}};
"""
    
    # Views group
    pbxproj += f"""\t\t{uuids['pbx_group_views']} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{file_refs['Views/ContentView.swift']},
\t\t\t\t{file_refs['Views/AuthenticationView.swift']},
\t\t\t\t{file_refs['Views/MainRunbotView.swift']},
\t\t\t\t{file_refs['Views/RunningView.swift']},
\t\t\t\t{file_refs['Views/SettingsView.swift']},
\t\t\t);
\t\t\tpath = Views;
\t\t\tsourceTree = \"<group>\";
\t\t}};
"""
    
    # Models group
    pbxproj += f"""\t\t{uuids['pbx_group_models']} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{file_refs['Models/AuthenticationManager.swift']},
\t\t\t\t{file_refs['Models/RunTracker.swift']},
\t\t\t\t{file_refs['Models/VoiceManager.swift']},
\t\t\t\t{file_refs['Models/AICoachManager.swift']},
\t\t\t\t{file_refs['Models/SupabaseManager.swift']},
\t\t\t\t{file_refs['Models/Mem0Manager.swift']},
\t\t\t\t{file_refs['Models/UserPreferences.swift']},
\t\t\t\t{file_refs['Models/RunDataModels.swift']},
\t\t\t\t{file_refs['Models/HealthManager.swift']},
\t\t\t\t{file_refs['Models/HeartZoneCalculator.swift']},
\t\t\t\t{file_refs['Models/WatchConnectivityManager.swift']},
\t\t\t);
\t\t\tpath = Models;
\t\t\tsourceTree = \"<group>\";
\t\t}};
"""
    
    pbxproj += """/* End PBXGroup section */

/* Begin PBXProject section */
"""
    
    # Project
    pbxproj += f"""\t\t{uuids['project']} = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastUpgradeCheck = 1600;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{uuids['pbx_target_watch']} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {generate_uuid()};
\t\t\tcompatibilityVersion = \"Xcode 14.0\";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {uuids['pbx_group_main']};
\t\t\tprojectDirPath = \"\";
\t\t\tprojectRoot = \"\";
\t\t\ttargets = (
\t\t\t\t{uuids['pbx_target_watch']},
\t\t\t);
\t\t}};
"""
    
    pbxproj += """/* End PBXProject section */

	};
	rootObject = """ + uuids['project'] + """ /* Project object */;
}
"""
    
    return pbxproj

# Create the project
project_path = "/Users/ranga/Desktop/Runbot/RunbotAIWatch"
xcodeproj_path = os.path.join(project_path, "RunbotAIWatch.xcodeproj")

# Create directories
os.makedirs(xcodeproj_path, exist_ok=True)

# Write pbxproj
pbxproj_content = create_pbxproj()
with open(os.path.join(xcodeproj_path, "project.pbxproj"), "w") as f:
    f.write(pbxproj_content)

print("✅ Created RunbotAIWatch.xcodeproj/project.pbxproj")

# Create workspace file
workspace_path = os.path.join(xcodeproj_path, "project.xcworkspace")
os.makedirs(workspace_path, exist_ok=True)

workspace_content = """<?xml version="1.0" encoding="UTF-8"?>
<Workspace version = "1.0">
   <FileRef location = "group:RunbotAIWatch.xcodeproj">
   </FileRef>
</Workspace>
"""

with open(os.path.join(workspace_path, "contents.xcworkspacedata"), "w") as f:
    f.write(workspace_content)

print("✅ Created workspace")








