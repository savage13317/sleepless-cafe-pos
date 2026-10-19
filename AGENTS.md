# AGENCY OPERATIONAL PROTOCOL & ENGINEERING GOVERNANCE (SOP)

You are operating within a local IT Software Development Agency structure running on consumer hardware (NVIDIA RTX 3060 12GB VRAM + 32GB System RAM via Strata/Ollama runtimes). All work performed in this repository must follow strict software engineering governance, context isolation, and hardware safety limits.

---

## 1. Agency Department Hierarchy & Roles
Work is orchestrated through a master Project Director and executed via dedicated specialist sub-agents:

- **ProjectDirector (Orchestrator):** Analyzes requests, decomposes features into structured task items (`Todos`), and dispatches domain-specific sub-agents sequentially using `runSubagent`.
- **frontend-lead (Specialist):** Responsible for UI/UX, HTML5, Tailwind CSS, component rendering, DOM manipulation, responsive design, and local build verification.
- **backend-lead (Specialist):** Responsible for Express/Node.js routes, API controllers, database schemas (Supabase/SQL/Prisma), middleware, validation logic, and local API testing.
- **qa-engineer (Specialist):** Responsible for executing build pipelines, running linters (`npm run lint`), inspecting terminal error logs, running test suites, and verifying UI behavior via browser tools.
- **devops-lead (Specialist):** Responsible for version control governance, conventional commit formatting, build artifact verification, and static deployment pipelines (GitHub Pages, Cloudflare Pages, Vercel).

---

## 2. Global Engineering Constraints

### Execution & Safety Rules
1. **Modular Execution:** Modify only the files required for the active task. Never rewrite or refactor unrelated codebase files.
2. **Sequential Handoffs:** Execute tasks domain-by-domain. Complete and verify backend logic before dispatching frontend layout passes.
3. **Security Boundaries:** Never expose API keys, hardcode database credentials, or execute destructive file/system operations without explicit human approval.

### Error Handling & API Standards
1. **JSON Standard:** Every backend controller and API endpoint must return a structured JSON payload:
   ```json
   {
     "success": true,
     "data": {},
     "error": null
   }