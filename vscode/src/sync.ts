import * as vscode from 'vscode';
import * as net from 'net';
import * as os from 'os';

interface Config {
    autoReload: boolean;
    syncInterval: number;
    socketPath: string;
}

interface TabInfo {
    path: string;
    active: boolean;
}

interface Message {
    type: 'tabs' | 'buffer_change';
    data: TabInfo[][] | { path: string };
}

interface Logger {
    debug(message: string): void;
    info(message: string): void;
    warn(message: string): void;
    error(message: string): void;
}

export class SyncManager {
    private config: Config;
    private client: net.Socket | null = null;
    private disposables: vscode.Disposable[] = [];
    private logger: Logger;

    constructor(config: Config) {
        this.config = this.normalizeConfig(config);
        // Initialize logger
        this.logger = {
            debug: (message: string) => {
                if (vscode.workspace.getConfiguration('shadowPlay').get('debug')) {
                    console.log(`[DEBUG] ${message}`);
                }
            },
            info: (message: string) => console.log(`[INFO] ${message}`),
            warn: (message: string) => console.warn(`[WARN] ${message}`),
            error: (message: string) => console.error(`[ERROR] ${message}`)
        };
    }

    private normalizeConfig(config: Config): Config {
        return {
            ...config,
            socketPath: config.socketPath.replace('~', os.homedir())
        };
    }

    public updateConfig(newConfig: Config): void {
        this.config = this.normalizeConfig(newConfig);
        this.restart();
    }

    public start(): void {
        this.connect();
    }

    private connect(): void {
        if (this.client) {
            return;
        }

        this.client = net.createConnection(this.config.socketPath)
            .on('connect', () => {
                console.log('Connected to Neovim');
                this.syncTabs();
            })
            .on('error', (err) => {
                console.error('Connection error:', err);
                this.client = null;
                // Try to reconnect after interval
                setTimeout(() => this.connect(), this.config.syncInterval);
            })
            .on('data', (data) => {
                try {
                    const message: Message = JSON.parse(data.toString());
                    this.handleMessage(message);
                } catch (err) {
                    console.error('Failed to parse message:', err);
                }
            })
            .on('close', () => {
                console.log('Connection closed');
                this.client = null;
                // Try to reconnect after interval
                setTimeout(() => this.connect(), this.config.syncInterval);
            });
    }

    private async handleMessage(message: Message): Promise<void> {
        switch (message.type) {
            case 'tabs':
                await this.handleTabSync(message.data as TabInfo[][]);
                break;
            case 'buffer_change':
                await this.handleBufferChange(message.data as { path: string });
                break;
        }
    }

    private async handleTabSync(tabs: TabInfo[][]): Promise<void> {
        this.logger.debug(`Handling tab sync with ${tabs.length} tabs`);
        
        // Get all active text editors
        const editors = vscode.window.tabGroups.all
            .flatMap(group => group.tabs)
            .filter(tab => tab.input instanceof vscode.TabInputText)
            .map(tab => (tab.input as vscode.TabInputText).uri);
            
        // Track which files we've processed
        const processedFiles = new Set<string>();
        
        // Process each tab from Neovim
        for (const tabInfo of tabs) {
            for (const buffer of tabInfo) {
                try {
                    const uri = vscode.Uri.file(buffer.path);
                    processedFiles.add(uri.fsPath);
                    
                    // Check if file is already open
                    const isOpen = editors.some(editor => editor.fsPath === uri.fsPath);
                    
                    if (!isOpen) {
                        this.logger.debug(`Opening new document: ${buffer.path}`);
                        // Open the document
                        const doc = await vscode.workspace.openTextDocument(uri);
                        await vscode.window.showTextDocument(doc, {
                            preview: false,
                            preserveFocus: !buffer.active
                        });
                    } else if (buffer.active) {
                        this.logger.debug(`Activating existing document: ${buffer.path}`);
                        // Activate existing document if needed
                        const doc = await vscode.workspace.openTextDocument(uri);
                        await vscode.window.showTextDocument(doc, {
                            preview: false,
                            preserveFocus: false
                        });
                    }
                } catch (error) {
                    this.logger.error(`Failed to handle buffer ${buffer.path}: ${error}`);
                }
            }
        }
        
        // Close tabs that are not in Neovim
        const tabsToClose = vscode.window.tabGroups.all
            .flatMap(group => group.tabs)
            .filter(tab => {
                if (!(tab.input instanceof vscode.TabInputText)) {
                    return false;
                }
                const uri = (tab.input as vscode.TabInputText).uri;
                return !processedFiles.has(uri.fsPath);
            });
            
        // Close tabs in reverse order to avoid index shifting
        for (const tab of tabsToClose.reverse()) {
            try {
                await vscode.window.tabGroups.close(tab);
            } catch (error) {
                this.logger.error(`Failed to close tab: ${error}`);
            }
        }
        
        this.logger.info('Tab synchronization completed');
    }

    private async handleBufferChange(data: { path: string }): Promise<void> {
        if (!this.config.autoReload) {
            return;
        }

        const uri = vscode.Uri.file(data.path);
        try {
            const doc = await vscode.workspace.openTextDocument(uri);
            await doc.save();
        } catch (err) {
            console.error('Failed to reload document:', err);
        }
    }

    public syncTabs(): void {
        if (!this.client) {
            return;
        }

        const tabs = this.getTabsInfo();
        this.sendMessage({
            type: 'tabs',
            data: tabs
        });
    }

    public syncBuffer(filePath: string): void {
        if (!this.client) {
            return;
        }

        this.sendMessage({
            type: 'buffer_change',
            data: {
                path: filePath
            }
        });
    }

    private getTabsInfo(): TabInfo[][] {
        const tabs: TabInfo[][] = [];
        const groups = vscode.window.tabGroups.all;

        for (const group of groups) {
            const groupTabs: TabInfo[] = [];
            for (const tab of group.tabs) {
                if (tab.input instanceof vscode.TabInputText) {
                    groupTabs.push({
                        path: tab.input.uri.fsPath,
                        active: tab === group.activeTab
                    });
                }
            }
            if (groupTabs.length > 0) {
                tabs.push(groupTabs);
            }
        }

        return tabs;
    }

    private sendMessage(message: Message): void {
        if (!this.client) {
            return;
        }

        try {
            this.client.write(JSON.stringify(message));
        } catch (err) {
            console.error('Failed to send message:', err);
        }
    }

    private restart(): void {
        if (this.client) {
            this.client.end();
            this.client = null;
        }
        this.connect();
    }

    public dispose(): void {
        if (this.client) {
            this.client.end();
            this.client = null;
        }
        
        for (const disposable of this.disposables) {
            disposable.dispose();
        }
        this.disposables = [];
    }
} 