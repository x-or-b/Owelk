#pragma once

#include <QDateTime>
#include <QHash>
#include <QObject>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>
#include <functional>

class QNetworkAccessManager;
class QNetworkReply;
class QTimer;
class ResearchStore;

// For You: new papers in the fields the reader follows. Topics (words and arXiv categories) are looked up
// on arXiv; followed collections ask Semantic Scholar for papers like theirs (by their arXiv IDs and
// DOIs); followed researchers and institutions ask OpenAlex for their new papers, which are always shown,
// first, whatever the AI makes of them. Papers found wait until added to the Library (the PDF is downloaded, named and
// filed) or dismissed; papers already in the Library or dismissed are not shown again. Checked when asked and, when on,
// once a day while Owelk runs. Topics, followed collections, the papers found with the AI's reasons and what became of
// them live in the library (foryou_* tables), so they sync; how often and how far back to look are settings (forYou.*)
// of this computer.
class ForYou final : public QObject {
    Q_OBJECT
    // The papers waiting, most relevant first: {id, title, authors, date, year, abstract, arxiv, doi, pdf,
    // hasPdf (a free PDF to fetch), url, source, sourceName, score, why}.
    Q_PROPERTY(QVariantList items READ items NOTIFY changed)
    // Whether anything is followed (a topic, a collection, a researcher or an institution).
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
    // The paper whose PDF is coming for a preview (its id), or empty.
    Q_PROPERTY(QString previewing READ previewing NOTIFY previewingChanged)
    // Looking up researchers and institutions by name (findPeople).
    Q_PROPERTY(bool findingPeople READ findingPeople NOTIFY findingPeopleChanged)
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
    QString previewing() const { return m_previewing; }
    bool findingPeople() const { return m_peopleRequests > 0; }
    // Reads what was found and starts the daily check (a little after launch, then every hour).
    void start();
    // Read again (rows arrived from another computer).
    void reload();

    // Topics: [{id, words, categories, on}]; words and categories are comma-separated.
    Q_INVOKABLE QVariantList topics() const;
    Q_INVOKABLE bool saveTopics(const QVariantList &topics);
    Q_INVOKABLE bool following(const QString &collectionId) const;
    Q_INVOKABLE void follow(const QString &collectionId, bool on);
    // Researchers and institutions followed: [{id, kind ("person" or "institution"), name, detail, on}].
    Q_INVOKABLE QVariantList people() const;
    // Looks them up on OpenAlex by name; answered by peopleFound(text, [{id, kind, name, detail, papers}],
    // problem). Asked on Return, not while typing: without a key every search spends the shared allowance.
    Q_INVOKABLE void findPeople(const QString &text);
    Q_INVOKABLE bool followPerson(const QVariantMap &person);
    // A paper's authors from its OpenAlex record, found by its OpenAlex ID, DOI, arXiv ID or (failing those) its
    // exact title, for Follow Author: answered by authorsFound(request, [{id, kind "person", name, detail (where
    // they work), position (first, middle or last), corresponding, institutions [{id, kind "institution", name,
    // detail}]}], problem). The last and the corresponding author come first: usually who leads the work.
    // paper: {openalex, doi, arxiv, title}.
    Q_INVOKABLE int findAuthors(const QVariantMap &paper);
    Q_INVOKABLE void unfollowPerson(const QString &id);
    Q_INVOKABLE void setPersonOn(const QString &id, bool on);
    // An OpenAlex key (optional, free) kept in the system keyring: its own daily allowance instead of the one
    // everyone on this network shares.
    // Opens Library › For You › Following, where what is followed is chosen (followingRequested).
    Q_INVOKABLE void showFollowing() { emit followingRequested(); }
    Q_INVOKABLE bool hasOpenAlexKey() const;
    Q_INVOKABLE bool setOpenAlexKey(const QString &key);
    // How many papers one source brings at most in a check ("topic:<id>", "collection:<id>", "person:<id>" or
    // "institution:<id>"): its own number, or 0 for the usual one (forYou.perSource). A setting of this computer.
    Q_INVOKABLE int perCheck(const QString &source) const;
    Q_INVOKABLE void setPerCheck(const QString &source, int count);
    // Whether a paper's source is a followed researcher or institution (those are always shown, first).
    static bool fromPerson(const QString &source);
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
    // A paper's PDF to read before deciding: fetched into <data>/foryou-preview (kept a week) and not
    // added to the Library; Add then uses it rather than fetching again. Answered by previewReady(id,
    // file) or previewFailed(id, why).
    Q_INVOKABLE void preview(const QString &id);
    // A paper's page opened (Open Page, Get PDF on Its Page): a PDF of it that then reaches the Library gets
    // Add's details and collection, and the paper leaves the list.
    Q_INVOKABLE void expect(const QString &id);
    // Whether the AI can be asked (set up in Settings › AI, and agreed to).
    Q_INVOKABLE bool aiReady() const;
    Q_INVOKABLE QString aiName() const;

signals:
    void changed();
    void settingsChanged();
    void checkingChanged();
    void addingChanged();
    void explainingChanged();
    void previewingChanged();
    void findingPeopleChanged();
    void peopleFound(const QString &text, const QVariantList &found, const QString &problem);
    void authorsFound(int request, const QVariantList &authors, const QString &problem);
    void followingRequested();
    void previewReady(const QString &id, const QUrl &file);
    void previewFailed(const QString &id, const QString &why);
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
    // One way of finding a paper on OpenAlex after another, until one gives its authors.
    void lookUpAuthors(int request, const QList<QUrl> &tries, const QString &title, int at);
    void finishAdd(const QVariantMap &item, const QUrl &file);
    // A PDF's bytes into the Library under the paper's name, then finishAdd.
    bool saveIntoLibrary(const QVariantMap &paper, const QByteArray &bytes);
    QString previewPath(const QString &id) const;
    // The details Add gives a paper (from arXiv or Semantic Scholar), and its collection.
    void finishDetails(const QVariantMap &paper, const QUrl &url);
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
    // Sources that answered in this check: one that reached none (offline) does not count as today's check.
    int m_jobCount = 0, m_answered = 0;
    QVariantList m_found;
    QStringList m_adding;
    QStringList m_addQueue;
    // Papers Add sent to the browser (the direct download failed), finished when they reach the Library.
    QHash<QString, QVariantMap> m_viaBrowser;
    QString m_previewing;
    QNetworkReply *m_previewReply = nullptr;
    bool m_explaining = false;
    int m_rankRequest = -1;
    QString m_aiProblem;
    int m_peopleRequests = 0;
    int m_authorRequest = 0;
};

namespace ForYouParse {
// The arXiv search_query for a topic: any of the words (comma-separated phrases) in any of the categories,
// submitted in [from, to].
QString arxivQuery(const QString &words, const QString &categories, const QDateTime &from, const QDateTime &to);
// Papers in an arXiv API answer (Atom) or a Semantic Scholar recommendations answer (JSON).
QVariantList arxivEntries(const QByteArray &atom);
QVariantList recommendations(const QByteArray &json);
// New works in an OpenAlex answer (the abstract put back together from its word index; an arXiv ID from an
// arxiv.org location or an arXiv DOI), and researchers ("person") or institutions in a search answer.
QVariantList openAlexWorks(const QByteArray &json);
QVariantList openAlexPeople(const QByteArray &json, const QString &kind);
// The authors of one OpenAlex work (its record, or the first result of a search), ordered as findAuthors gives them;
// with a title, only a work of that title (letters and digits compared).
QVariantList openAlexAuthors(const QByteArray &json, const QString &title = QString());
// An address a PDF can be fetched from (not a DOI link, which leads to a publisher's page).
bool isPdfAddress(const QString &address);
}
