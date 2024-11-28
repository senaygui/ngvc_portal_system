class StudentGrade < ApplicationRecord
  after_create :generate_assessment
  after_save :update_subtotal
  # after_save :generate_grade
  after_save :add_course_registration
  after_save :update_grade_report
  # #validation
  validates :student, presence: true
  validates :course, presence: true
  #  validates :course_registration, presence: true
  # #assocations
  belongs_to :course_registration, optional: true
  belongs_to :student
  belongs_to :course
  belongs_to :department, optional: true
  belongs_to :program, optional: true
  has_many :assessments, dependent: :destroy
  accepts_nested_attributes_for :assessments, reject_if: :all_blank, allow_destroy: true
  has_many :grade_changes
  has_many :makeup_exams

  def add_course_registration
    unless course_registration.present?
      cr = CourseRegistration.where(student_id: student.id, course_id: course.id).last.id
      update_columns(course_registration_id: cr)
    end
  end

  def assesment_total1
    # assessments.collect { |oi| oi.valid? ? (oi.result) : 0 }.sum
    assessments.sum(:result)
  end

  def update_subtotal
    update_columns(assesment_total: assessments.sum(:result)) if assessments.any?
  end

  def generate_grade
    if assessments.any?
      if assessments.where(result: nil).empty?
        grade_in_letter = student.program.grade_systems.last.grades.where('min_row_mark <= ?', assesment_total1).where(
          'max_row_mark >= ?', assesment_total1
        ).last.letter_grade
        grade_letter_value = student.program.grade_systems.last.grades.where('min_row_mark <= ?', assesment_total1).where(
          'max_row_mark >= ?', assesment_total1
        ).last.grade_point * course.credit_hour
        update_columns(letter_grade: grade_in_letter)
        update_columns(grade_point: grade_letter_value)
      elsif assessments.where(result: nil, final_exam: true).present?
        update_columns(letter_grade: 'NG')
        # needs to be empty and after a week changes to f
        update_columns(grade_point: 0)
      elsif assessments.where(result: nil, final_exam: false).present?
        update_columns(letter_grade: 'I')
        # needs to be empty and after a week changes to f
        update_columns(grade_point: 0)
      end
    end
    # self[:grade_in_letter] = grade_in_letter
  end

  private

  def generate_assessment
    course.assessment_plans.each do |plan|
      Assessment.create do |assessment|
        assessment.course_id = course.id
        assessment.student_id = student.id
        assessment.student_grade_id = id
        assessment.assessment_plan_id = plan.id
        assessment.final_exam = plan.final_exam
        assessment.created_by = created_by
      end
    end
  end

  def update_grade_report
    if course_registration.semester_registration.grade_report.present?
      if student.grade_reports.count == 1
        total_credit_hour = course_registration.semester_registration.course_registrations.where(enrollment_status: 'enrolled').collect do |oi|
          (oi.student_grade.letter_grade != 'I') && (oi.student_grade.letter_grade != 'NG') ? oi.course.credit_hour : 0
        end.sum
        total_grade_point = course_registration.semester_registration.course_registrations.where(enrollment_status: 'enrolled').collect do |oi|
          (oi.student_grade.letter_grade != 'I') && (oi.student_grade.letter_grade != 'NG') ? oi.student_grade.grade_point : 0
        end.sum
        sgpa = total_credit_hour == 0 ? 0 : (total_grade_point / total_credit_hour).round(1)
        cumulative_total_credit_hour = total_credit_hour
        cumulative_total_grade_point = total_grade_point
        cgpa = cumulative_total_credit_hour == 0 ? 0 : (cumulative_total_grade_point / cumulative_total_credit_hour).round(1)
        course_registration.semester_registration.grade_report.update(total_credit_hour:,
                                                                      total_grade_point:, sgpa:, cumulative_total_credit_hour:, cumulative_total_grade_point:, cgpa:)
        if course_registration.semester_registration.course_registrations.joins(:student_grade).pluck(:letter_grade).include?('I').present? || course_registration.semester_registration.course_registrations.joins(:student_grade).pluck(:letter_grade).include?('NG').present?
          academic_status = 'Incomplete'
        else
          academic_status = program.grade_systems.last.academic_statuses.where('min_value <= ?', cgpa).where(
            'max_value >= ?', cgpa
          ).last.status
        end

        if course_registration.semester_registration.grade_report.academic_status != academic_status
          if ((course_registration.semester_registration.grade_report.academic_status == 'Dismissal') || (course_registration.semester_registration.grade_report.academic_status == 'Incomplete')) && ((academic_status != 'Dismissal') || (academic_status != 'Incomplete'))
            if program.program_semester > student.semester
              promoted_semester = student.semester + 1
              student.update_columns(semester: promoted_semester)
            elsif (program.program_semester == student.semester) && (program.program_duration > student.year)
              promoted_year = student.year + 1
              student.update_columns(semester: 1)
              student.update_columns(year: promoted_year)
            end
          end
          course_registration.semester_registration.grade_report.update_columns(academic_status:)
        end
      else
        total_credit_hour = course_registration.semester_registration.course_registrations.where(enrollment_status: 'enrolled').collect do |oi|
          (oi.student_grade.letter_grade != 'I') && (oi.student_grade.letter_grade != 'NG') ? oi.course.credit_hour : 0
        end.sum
        total_grade_point = course_registration.semester_registration.course_registrations.where(enrollment_status: 'enrolled').collect do |oi|
          (oi.student_grade.letter_grade != 'I') && (oi.student_grade.letter_grade != 'NG') ? oi.student_grade.grade_point : 0
        end.sum
        sgpa = total_credit_hour == 0 ? 0 : (total_grade_point / total_credit_hour).round(1)

        cumulative_total_credit_hour = GradeReport.where(student_id:).order('created_at ASC').last.cumulative_total_credit_hour + total_credit_hour
        cumulative_total_grade_point = GradeReport.where(student_id:).order('created_at ASC').last.cumulative_total_grade_point + total_grade_point
        cgpa = (cumulative_total_grade_point / cumulative_total_credit_hour).round(1)

        academic_status = program.grade_systems.last.academic_statuses.where('min_value <= ?', cgpa).where(
          'max_value >= ?', cgpa
        ).last.status

        course_registration.semester_registration.grade_report.update(total_credit_hour:,
                                                                      total_grade_point:, sgpa:, cumulative_total_credit_hour:, cumulative_total_grade_point:, cgpa:)

        if course_registration.semester_registration.course_registrations.joins(:student_grade).pluck(:letter_grade).include?('I').present? || course_registration.semester_registration.course_registrations.joins(:student_grade).pluck(:letter_grade).include?('NG').present?
          academic_status = 'Incomplete'
        else
          academic_status = program.grade_systems.last.academic_statuses.where('min_value <= ?', cgpa).where(
            'max_value >= ?', cgpa
          ).last.status
        end

        if course_registration.semester_registration.grade_report.academic_status != academic_status
          if ((course_registration.semester_registration.grade_report.academic_status == 'Dismissal') || (course_registration.semester_registration.grade_report.academic_status == 'Incomplete')) && ((academic_status != 'Dismissal') || (academic_status != 'Incomplete'))
            if program.program_semester > student.semester
              promoted_semester = student.semester + 1
              student.update_columns(semester: promoted_semester)
            elsif (program.program_semester == student.semester) && (program.program_duration > student.year)
              promoted_year = student.year + 1
              student.update_columns(semester: 1)
              student.update_columns(year: promoted_year)
            end
          end
          course_registration.semester_registration.grade_report.update_columns(academic_status:)
        end

      end
    end
  end

  def moodle_grade
    url = URI('https://lms.ngvc.edu.et/webservice/rest/server.php')
    moodle = MoodleRb.new('dbf3e3c6f2774f33f9e1313caf1ad212', 'https://lms.ngvc.edu.et/webservice/rest/server.php')
    lms_student = moodle.users.search(email: "#{student.email}")
    user = lms_student[0]['id']
    https = Net::HTTP.new(url.host, url.port)
    https.use_ssl = true

    request = Net::HTTP::Post.new(url)
    form_data = [%w[wstoken dbf3e3c6f2774f33f9e1313caf1ad212],
                 %w[wsfunction gradereport_overview_get_course_grades], %w[moodlewsrestformat json], ['userid', "#{user}"]]
    request.set_form form_data, 'multipart/form-data'
    response = https.request(request)
    # puts response.read_body
    results =  JSON.parse(response.read_body)
    course_code = moodle.courses.search("#{course_registration.course.course_code}")
    course = course_code['courses'][0]['id']

    total_grade = results['grades'].map { |h1| h1['rawgrade'] if h1['courseid'] == course }.compact.first
    grade_letter = results['grades'].map { |h1| h1['grade'] if h1['courseid'] == course }.compact.first
    # self.update_columns(grade_in_letter: grade_letter)
    update(assesment_total: total_grade.to_f)
  end
end
