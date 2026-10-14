import { request, streamRequest } from '../../services/api';
import { authorizePrivacy } from '../../services/privacy';

type Tab = 'chat' | 'runs' | 'knowledge' | 'evals' | 'diagnostics';
type Row = Record<string, any>;
type Event = { detail: { value: string | number | boolean }; currentTarget: { dataset: Record<string, string> } };
const defaultSkill = 'https://github.com/alchaincyf/zhangxuefeng-skill/blob/main/SKILL.md';
let pollTimer: ReturnType<typeof setInterval> | undefined;

Page({
  data: {
    tabs: [{ id: 'chat', label: '对话' }, { id: 'runs', label: '运行' }, { id: 'knowledge', label: '知识库' }, { id: 'evals', label: '评测' }, { id: 'diagnostics', label: '诊断' }],
    tab: 'chat' as Tab, loading: false, busy: false, error: '', status: '',
    conversations: [] as Row[], activeConversationId: 0, conversationTitle: '', messages: [] as Row[],
    skillUrl: defaultSkill, titleInput: '', question: '', answer: '',
    runs: [] as Row[], activeRun: null as Row | null,
    documents: [] as Row[], documentDetail: null as Row | null,
    suites: [] as Row[], activeSuiteId: 0, activeSuite: null as Row | null, suiteCases: [] as Row[],
    evalReport: null as Row | null, jobStatus: '',
    diagnostics: null as Row | null,
    suiteName: '', suiteUrl: defaultSkill, suiteDescription: '',
    caseTitle: '', caseQuestion: '', expectedBehavior: '', scoringFocus: '',
  },
  onShow() { void this.refresh(); },
  onHide() { if (pollTimer) clearInterval(pollTimer); pollTimer = undefined; },
  async refresh() {
    if (this.data.tab === 'chat') await this.loadConversations();
    else if (this.data.tab === 'runs') await this.loadRuns();
    else if (this.data.tab === 'knowledge') await this.loadDocuments();
    else if (this.data.tab === 'evals') await this.loadSuites();
    else await this.loadDiagnostics();
  },
  switchTab(event: Event) {
    const tab = String(event.currentTarget.dataset.tab) as Tab;
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = undefined;
    this.setData({ tab, error: '', status: '' });
    void this.refresh();
  },
  onSkillUrl(event: Event) { this.setData({ skillUrl: String(event.detail.value) }); },
  onTitle(event: Event) { this.setData({ titleInput: String(event.detail.value) }); },
  onQuestion(event: Event) { this.setData({ question: String(event.detail.value) }); },

  async loadConversations() {
    this.setData({ loading: true, error: '' });
    try {
      const conversations = await request<Row[]>('GET', 'skill-agent/conversations');
      this.setData({ conversations, loading: false });
      if (this.data.activeConversationId && conversations.some((row) => row.id === this.data.activeConversationId)) await this.openConversationById(this.data.activeConversationId);
    } catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '加载对话失败' }); }
  },
  async openConversationById(id: number) {
    try {
      const detail = await request<Row>('GET', `skill-agent/conversations/${id}`);
      this.setData({ activeConversationId: id, conversationTitle: detail.conversation?.title ?? '', skillUrl: detail.conversation?.skill_url ?? defaultSkill, messages: detail.messages ?? [] });
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '读取对话失败' }); }
  },
  openConversation(event: Event) { void this.openConversationById(Number(event.currentTarget.dataset.id)); },
  onConversationPick(event: Event) {
    const row = this.data.conversations[Number(event.detail.value)];
    if (row) void this.openConversationById(row.id);
  },
  async newConversation() {
    this.setData({ activeConversationId: 0, conversationTitle: '', messages: [], skillUrl: defaultSkill, titleInput: '', question: '', error: '' });
  },
  async createConversation() {
    const skill_url = this.data.skillUrl.trim();
    if (!skill_url) { wx.showToast({ title: '请填写 Skill 链接', icon: 'none' }); return; }
    try {
      const row = await request<Row>('POST', 'skill-agent/conversations', { skill_url, title: this.data.titleInput.trim() });
      this.setData({ activeConversationId: row.id, conversationTitle: row.title, titleInput: '' });
      await this.loadConversations();
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '创建对话失败' }); }
  },
  async sendMessage() {
    const question = this.data.question.trim();
    if (!question || this.data.busy) return;
    let id = this.data.activeConversationId;
    try {
      if (!id) {
        const row = await request<Row>('POST', 'skill-agent/conversations', { skill_url: this.data.skillUrl.trim() || defaultSkill, title: this.data.titleInput.trim() });
        id = row.id;
        this.setData({ activeConversationId: id, conversationTitle: row.title });
      }
      this.setData({ question: '', busy: true, status: '正在思考…', error: '', answer: '' });
      await streamRequest(`skill-agent/conversations/${id}/messages/stream`, { question }, (name, payload) => {
        if (name === 'delta') this.setData({ answer: this.data.answer + String(payload.content ?? '') });
        else if (name === 'status') this.setData({ status: String(payload.message ?? '正在处理…') });
        else if (name === 'done') this.setData({ status: '完成' });
        else if (name === 'error') this.setData({ status: String(payload.message ?? '运行失败') });
      });
      await this.loadConversations();
      await this.openConversationById(id);
    } catch (error) {
      this.setData({ error: error instanceof Error ? error.message : '发送失败，请重试' });
      if (id) await this.openConversationById(id);
    } finally { this.setData({ busy: false }); }
  },
  renameConversation() {
    wx.showModal({ title: '重命名对话', editable: true, placeholderText: this.data.conversationTitle || '对话标题', success: async (result) => {
      if (!result.confirm || !result.content?.trim()) return;
      try {
        await request('PUT', `skill-agent/conversations/${this.data.activeConversationId}`, { title: result.content.trim() });
        await this.loadConversations();
      } catch (error) { this.setData({ error: error instanceof Error ? error.message : '重命名失败' }); }
    } });
  },
  deleteConversation() {
    wx.showModal({ title: '删除这段对话？', content: '对话消息会被删除。', success: async (result) => {
      if (!result.confirm) return;
      try { await request('DELETE', `skill-agent/conversations/${this.data.activeConversationId}`); await this.newConversation(); await this.loadConversations(); }
      catch (error) { this.setData({ error: error instanceof Error ? error.message : '删除失败' }); }
    } });
  },

  async loadRuns() {
    this.setData({ loading: true });
    try { const runs = await request<Row[]>('GET', 'skill-agent/runs'); this.setData({ runs, loading: false }); }
    catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '加载运行记录失败' }); }
  },
  async startRun() {
    const skill_url = this.data.skillUrl.trim();
    const question = this.data.question.trim();
    if (!skill_url || !question || this.data.busy) return;
    this.setData({ busy: true, status: '正在启动运行…', error: '', activeRun: null });
    try {
      await streamRequest('skill-agent/runs/stream', { skill_url, question }, (name, payload) => {
        if (name === 'delta') this.setData({ answer: this.data.answer + String(payload.content ?? '') });
        else if (name === 'status') this.setData({ status: String(payload.message ?? '正在运行…') });
        else if (name === 'done') this.setData({ status: '运行完成' });
        else if (name === 'error') this.setData({ status: String(payload.message ?? '运行失败') });
      });
      this.setData({ question: '' });
      await this.loadRuns();
      if (this.data.runs.length) await this.openRunById(this.data.runs[0].id);
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '运行失败，请重试' }); }
    finally { this.setData({ busy: false }); }
  },
  async openRunById(id: number) { try { this.setData({ activeRun: await request<Row>('GET', `skill-agent/runs/${id}`) }); } catch (error) { this.setData({ error: error instanceof Error ? error.message : '读取运行记录失败' }); } },
  openRun(event: Event) { void this.openRunById(Number(event.currentTarget.dataset.id)); },
  async rerun() {
    const id = Number(this.data.activeRun?.id);
    if (!id) return;
    try { const input = await request<{ skill_url: string; question: string }>('POST', `skill-agent/runs/${id}/rerun`); this.setData({ tab: 'runs', skillUrl: input.skill_url, question: input.question, activeRun: null }); }
    catch (error) { this.setData({ error: error instanceof Error ? error.message : '无法重跑' }); }
  },

  async loadDocuments() {
    this.setData({ loading: true });
    try {
      const documents = await request<Row[]>('GET', 'skill-agent/knowledge');
      this.setData({ documents, loading: false });
      const pending = documents.some((item) => item.status === 'queued' || item.status === 'indexing');
      if (pending && !pollTimer) pollTimer = setInterval(() => { void this.loadDocuments(); }, 2000);
      else if (!pending && pollTimer) { clearInterval(pollTimer); pollTimer = undefined; }
    }
    catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '加载知识库失败' }); }
  },
  async uploadKnowledge() {
    try { await authorizePrivacy(); }
    catch (error) { wx.showToast({ title: error instanceof Error ? error.message : '无法使用附件', icon: 'none' }); return; }
    wx.chooseMessageFile({ count: 1, type: 'file', extension: ['md', 'markdown', 'txt', 'pdf'], success: (result) => {
      const file = result.tempFiles[0];
      if (!file) return;
      if (file.size > 10 * 1024 * 1024) { wx.showToast({ title: '文件不能超过 10 MB', icon: 'none' }); return; }
      this.setData({ busy: true });
      wx.getFileSystemManager().readFile({ filePath: file.path, encoding: 'base64', success: async (read) => {
        try {
          await request('POST', 'skill-agent/knowledge/upload', { filename: file.name, content_base64: String(read.data) });
          await this.loadDocuments();
        } catch (error) { this.setData({ error: error instanceof Error ? error.message : '上传失败' }); }
        finally { this.setData({ busy: false }); }
      }, fail: () => { this.setData({ busy: false, error: '无法读取所选文件' }); } });
    } });
  },
  async knowledgeAction(event: Event) {
    const document = this.data.documents[Number(event.currentTarget.dataset.index)];
    const action = event.currentTarget.dataset.action;
    try {
      if (action === 'delete') await request('DELETE', `skill-agent/knowledge/${document.id}`);
      else if (action === 'reindex') await request('POST', `skill-agent/knowledge/${document.id}/reindex`);
      else this.setData({ documentDetail: await request<Row>('GET', `skill-agent/knowledge/${document.id}`) });
      await this.loadDocuments();
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '操作失败' }); }
  },

  async loadSuites() {
    this.setData({ loading: true });
    try {
      const suites = await request<Row[]>('GET', 'skill-agent/evals/suites');
      this.setData({ suites, loading: false });
      if (this.data.activeSuiteId) await this.openSuiteById(this.data.activeSuiteId);
    } catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '加载评测失败' }); }
  },
  async openSuiteById(id: number) {
    try { const result = await request<Row>('GET', `skill-agent/evals/suites/${id}`); this.setData({ activeSuiteId: id, activeSuite: result.suite, suiteCases: result.cases ?? [] }); }
    catch (error) { this.setData({ error: error instanceof Error ? error.message : '读取测试集失败' }); }
  },
  openSuite(event: Event) { void this.openSuiteById(Number(event.currentTarget.dataset.id)); },
  onSuiteField(event: Event) { this.setData({ [`${event.currentTarget.dataset.field}`]: String(event.detail.value) }); },
  async createSuite() {
    try {
      const suite = await request<Row>('POST', 'skill-agent/evals/suites', { name: this.data.suiteName, skill_url: this.data.suiteUrl, description: this.data.suiteDescription });
      this.setData({ suiteName: '', suiteDescription: '' });
      await this.loadSuites();
      await this.openSuiteById(suite.id);
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '创建测试集失败' }); }
  },
  async addCase() {
    if (!this.data.activeSuiteId) return;
    try {
      await request('POST', `skill-agent/evals/suites/${this.data.activeSuiteId}/cases`, { title: this.data.caseTitle, question: this.data.caseQuestion, expected_behavior: this.data.expectedBehavior, scoring_focus: this.data.scoringFocus });
      this.setData({ caseTitle: '', caseQuestion: '', expectedBehavior: '', scoringFocus: '' });
      await this.openSuiteById(this.data.activeSuiteId);
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '添加用例失败' }); }
  },
  async runSuite() {
    if (!this.data.activeSuiteId) return;
    try {
      const result = await request<{ eval_run_id: number; job_id: number }>('POST', `skill-agent/evals/suites/${this.data.activeSuiteId}/run`);
      this.setData({ jobStatus: 'queued', error: '' });
      if (pollTimer) clearInterval(pollTimer);
      pollTimer = setInterval(async () => {
        try {
          const report = await request<Row>('GET', `skill-agent/evals/runs/${result.eval_run_id}`);
          this.setData({ evalReport: report, jobStatus: report.run?.status ?? '' });
          if (!['queued', 'running'].includes(report.run?.status)) { if (pollTimer) clearInterval(pollTimer); pollTimer = undefined; }
        } catch (error) { this.setData({ error: error instanceof Error ? error.message : '读取评测进度失败' }); }
      }, 2000);
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '无法启动评测' }); }
  },
  async loadDiagnostics() {
    this.setData({ loading: true });
    try { this.setData({ diagnostics: await request<Row>('GET', 'skill-agent/diagnostics'), loading: false }); }
    catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '读取诊断失败' }); }
  },
  retry() { void this.refresh(); },
  closeDocumentDetail() { this.setData({ documentDetail: null }); },
});
