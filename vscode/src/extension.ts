import * as vscode from 'vscode';
import { SyncManager } from './sync';

let syncManager: SyncManager;

export function activate(context: vscode.ExtensionContext) {
    const config = vscode.workspace.getConfiguration('shadowPlay');
    
    syncManager = new SyncManager({
        autoReload: config.get('autoReload') as boolean,
        syncInterval: config.get('syncInterval') as number,
        socketPath: config.get('socketPath') as string
    });
    
    // Watch for configuration changes
    context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration(e => {
            if (e.affectsConfiguration('shadowPlay')) {
                const newConfig = vscode.workspace.getConfiguration('shadowPlay');
                syncManager.updateConfig({
                    autoReload: newConfig.get('autoReload') as boolean,
                    syncInterval: newConfig.get('syncInterval') as number,
                    socketPath: newConfig.get('socketPath') as string
                });
            }
        })
    );
    
    // Watch for tab changes
    context.subscriptions.push(
        vscode.window.onDidChangeActiveTextEditor(() => {
            syncManager.syncTabs();
        }),
        vscode.workspace.onDidCloseTextDocument(() => {
            syncManager.syncTabs();
        }),
        vscode.workspace.onDidOpenTextDocument(() => {
            syncManager.syncTabs();
        })
    );
    
    // Watch for file saves
    context.subscriptions.push(
        vscode.workspace.onDidSaveTextDocument(document => {
            syncManager.syncBuffer(document.uri.fsPath);
        })
    );
    
    // Start sync service
    syncManager.start();
}

export function deactivate() {
    if (syncManager) {
        syncManager.dispose();
    }
}