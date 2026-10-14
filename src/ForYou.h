#pragma once

#include <QDateTime>
#include <QObject>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>
#include <functional>

class QNetworkAccessManager;
class QTimer;
class ResearchStore;

// For You: new papers in the fields the reader follows. Topics (words and arXiv categories) are looked up
// on arXiv; followed collections ask Semantic Scholar for papers like theirs (by their arXiv IDs and
// DOIs). Papers found wait until added to the Library (the PDF is downloaded, named and filed) or
// dismissed; papers already in the Library or dismissed are not shown again. Checked when asked and, when
// on, once a day while Owelk runs. Topics, followed collections, the papers found with the AI's reasons and
// what became of them live in the library (foryou_* tables), so they sync; how often and how far back to
// look are settings (forYou.*) of this computer.
class ForYou final : public QObject {
    Q_OBJECT
    // The papers waiting, most relevant first: {id, title, authors, date, year, abstract, arxiv, doi, pdf,
    // hasPdf (a free PDF to fetch), url, source, sourceName, score, why}.
    Q_PROPERTY(QVariantList items READ items NOTIFY changed)
    // Whether anything is followed (a topic turned on or a collection).
    Q_PROPERTY(bool configured READ configured NOTIFY settingsChanged)
    Q_PROPERTY(bool checking READ checking NOTIFY checkingChanged)
    // When the last check finished (empty before the first), and what went wrong in it.
    Q_PROPERTY(QDateTime lastChecked READ lastChecked NOTIFY changed)
    Q_PROPERTY(QString problem READ problem NOTIFY changed)
    // Papers being downloaded by Add (their ids).
    Q_PROPERTY(QStringList adding READ adding NOTIFY addingChanged)
    // The AI reading the papers found (Explain), and what went wrong the last time.
    Q_PROPERTY(bool explaining READ explaining NOTIFY explainingChanged)
    Q_PROPERTY(QString aiProblem READ aiProblem NOTIFY changed)
public:
    explicit ForYou(ResearchStore *store, QObject *parent = nullptr);
    QVariantList items() const;
    bool configured() const;
    bool checking() const { return m_checking; }
    QDateTime lastChecked() const { return m_lastChecked; }
    QString problem() const { return m_problem; }
    QStringList adding() const { return m_adding; }
    bool explaining() const { return m_explaining; }
    QString aiProblem() const { return m_aiProblem; }
    // Reads what was found and starts the daily check (a little after launch, then every hour).
    void start();
    // Read again (rows arrived from another computer).
    void reload();

    // Topics: [{id, words, categories, on}]; words and categories are comma-separated.
    Q_INVOKABLE QVariantList topics() const;
    Q_INVOKABLE bool saveTopics(const QVariantList &topics);
    Q_INVOKABLE bool following(const QString &collectionId) const;
    Q_INVOKABLE void follow(const QString &collectionId, bool on);
    // How many of a collection's papers can be looked up (they have an arXiv ID or a DOI).
    Q_INVOKABLE int usablePapers(const QString &collectionId) const;
    // Where the papers shown came from: [{key, name, count}].
    Q_INVOKABLE QVariantList sources() const;
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void dismiss(const QStringList &ids);
    // Downloads each paper's PDF into the Library (into its collection when it came from one). A paper
    // with no PDF to fetch opens its page instead (webRequested).
    Q_INVOKABLE void add(const QStringList &ids);
    // The AI scores the papers not yet explained (0-100, most relevant first) and gives each one sentence on
    // why (score, why), from what is followed. Done after each check when forYou.ai is on.
    Q_INVOKABLE void explain();
    // Whether the AI can be asked (set up in Settings › AI, and agreed to).
    Q_INVOKABLE bool aiReady() const;
    Q_INVOKABLE QString aiName() const;

signals:
    void changed();
    void settingsChanged();
    void checkingChanged();
    void addingChanged();
    void explainingChanged();
    void webRequested(const QUrl &url);

private:
    struct Job {
        QString source, sourceName;
        std::function<void(Job)> run;
    };
    void checkIfDue();
    void runNext();
    void finishCheck();
    void found(const QVariantList &papers, const QString &source, const QString &sourceName);
    void addNext();
    void finishAdd(const QVariantMap &item, const QUrl &file);
    QVariantMap item(const QString &id) const;
    void ranked(int request, const QVariantList &ranking, const QString &error);
    // Papers now in the Library (added here, or a PDF got from their page) leave the list.
    void dropKept();
    // What is followed, as text for the AI: topics, and some titles from each followed collection.
    QString interests() const;
    // Most relevant first (papers the AI scored), then newest.
    void sortItems();
    void load();
    bool exec(const QString &sql, const QVariantList &values) const;
    QDateTime since() const;
    ResearchStore *m_store;
    QNetworkAccessManager *m_network = nullptr;
    QTimer *m_daily = nullptr;
    QTimer *m_libraryCheck = nullptr;
    QVariantList m_items;
    // Papers dismissed or added (here or on another computer): not suggested again.
    QStringList m_handled;
    QDateTime m_lastChecked;
    QString m_problem;
    QStringList m_problems;
    bool m_checking = false;
    QList<Job> m_jobs;
    int m_jobCount = 0;
    QVariantList m_found;
    QStringList m_adding;
    QStringList m_addQueue;
    bool m_explaining = false;
    int m_rankRequest = -1;
    QString m_aiProblem;
};

namespace ForYouParse {
// The arXiv search_query for a topic: any of the words (comma-separated phrases) in any of the categories,
// submitted in [from, to].
QString arxivQuery(const QString &words, const QString &categories, const QDateTime &from, const QDateTime &to);
// Papers in an arXiv API answer (Atom) or a Semantic Scholar recommendations answer (JSON).
QVariantList arxivEntries(const QByteArray &atom);
QVariantList recommendations(const QByteArray &json);
// An address a PDF can be fetched from (not a DOI link, which leads to a publisher's page).
bool isPdfAddress(const QString &address);
}
