# 项目类型识别参考

## 配置文件 → 技术栈映射

| 配置文件 | 语言/生态 | 安装命令 | 运行命令 |
|---------|----------|---------|---------|
| `package.json` | Node.js / JavaScript / TypeScript | `npm install` / `yarn` / `pnpm install` | 看 `scripts` 字段 |
| `pyproject.toml` | Python (现代) | `pip install -e .` / `poetry install` | 看入口点 |
| `setup.py` | Python (传统) | `pip install -e .` | `python setup.py` |
| `requirements.txt` | Python | `pip install -r requirements.txt` | `python main.py` |
| `Cargo.toml` | Rust | `cargo build` | `cargo run` |
| `go.mod` | Go | `go mod download` | `go run ./...` |
| `pom.xml` | Java (Maven) | `mvn install` | `mvn exec:java` |
| `build.gradle` | Java (Gradle) | `gradle build` | `gradle run` |
| `Gemfile` | Ruby | `bundle install` | `bundle exec ruby main.rb` |
| `*.csproj` | .NET / C# | `dotnet restore` | `dotnet run` |
| `composer.json` | PHP | `composer install` | `php artisan serve` 等 |
| `pubspec.yaml` | Dart / Flutter | `flutter pub get` | `flutter run` |
| `Makefile` | C/C++ 或通用 | `make` | `make run` |
| `CMakeLists.txt` | C/C++ | `cmake .. && make` | `./build/bin/...` |

## 常见框架识别

从 `package.json` 的 dependencies 中识别：
- `express` / `koa` / `fastify` → Node.js Web 框架
- `react` / `vue` / `angular` / `svelte` → 前端框架
- `next` / `nuxt` → 全栈框架
- `nestjs` → Node.js 企业级框架
- `electron` → 桌面应用
- `react-native` / `expo` → 移动应用

从 `pyproject.toml` / `requirements.txt` 中识别：
- `django` → Django Web 框架
- `flask` / `fastapi` → 轻量 Web 框架
- `scrapy` → 爬虫框架
- `pandas` / `numpy` → 数据科学
- `torch` / `tensorflow` → 机器学习
- `celery` → 任务队列
- `sqlalchemy` → ORM

## 项目结构模式

- `src/main/java/` → Maven/Gradle Java 项目
- `app/` + `routes/` + `views/` → Rails 或类似 MVC
- `src/app/` + `src/components/` → Angular
- `pages/` + `components/` → Next.js / Nuxt
- `cmd/` + `internal/` → Go 标准布局
- `src/lib/` → 库项目
- `bin/` → CLI 工具
