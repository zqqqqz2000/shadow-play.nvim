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
    data: any;
}

export class SyncManager {
    private config: Config;
    private client: net.Socket | null = null;
    private disposables: vscode.Disposable[] = [];

    constructor(config: Config) {
        this.config = this.normalizeConfig(config);
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
                await this.handleTabSync(message.data);
                break;
            case 'buffer_change':
                await this.handleBufferChange(message.data);
                break;
        }
    }

    private async handleTabSync(tabs: TabInfo[][]): Promise<void> {
        // TODO: Implement tab synchronization logic
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