## Description

<!-- Briefly describe what this PR does. What problem does it solve? -->

## Type of Change

- [ ] Bug fix (non-breaking change)
- [ ] New feature (non-breaking change)
- [ ] Breaking change (fix or feature that would break existing behavior)
- [ ] Test addition/improvement
- [ ] Documentation update
- [ ] CI/CD pipeline change

## Checklist

### Code Quality
- [ ] Code follows project conventions and style
- [ ] No unnecessary comments, dead code, or debugging artifacts
- [ ] Error handling is appropriate for the context

### Testing
- [ ] New tests added for new functionality
- [ ] All existing tests pass locally (`python run_tests.py`)
- [ ] Tier 1 pre-commit hook passes (if `.githooks/pre-commit` is configured)

### Lua-Specific
- [ ] All loops yield appropriately (no TMI risk)
- [ ] Large tables are nilled after use to assist GC
- [ ] Event-driven patterns used where applicable (OC compatibility)
- [ ] Cooperative multitasking respected (coroutine.yield / os.sleep where needed)

### Documentation
- [ ] README updated if needed
- [ ] API changes documented
- [ ] Inline comments explain non-obvious logic

## Test Plan

<!-- Describe how to verify this change. Include commands to run. -->

```
# Clone and run tests
git checkout <branch>
pip install -r requirements.txt
python run_tests.py
```

## Related Issues

<!-- Link related issues: Fixes #123, Relates to #456 -->
